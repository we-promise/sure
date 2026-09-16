require "test_helper"
require_relative "../../support/account_sync_input_test_helper"

class Account::SyncQueueTest < ActiveSupport::TestCase
  include AccountSyncInputTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  test "provider handoff seals an encrypted exact input and replays into the same child" do
    with_account_input do
      sync = enqueue_account_handoff
      input = sync.verify_account_inputs!.sole
      assert sync.account_inputs_sealed_at
      assert_equal @handoff.payload, input.payload
      assert_equal @provider_sync.id, input.provider_sync_id
      assert_equal @handoff.payload.fetch("source_batch_id"), input.resolve!.fetch(:source_batch).id
      assert_provider_column_encrypted(input, :payload, "statement_sha256")
      assert_no_difference [ "Sync.count", "Account::SyncInput.count" ] do
        assert_equal sync.id, enqueue_account_handoff.id
      end
    end
  end

  test "ad hoc calculation behind a running provider child copies its selected source without mutating the child" do
    with_account_input do
      first = enqueue_account_handoff
      first.start!
      original = first.attributes
      next_sync = @account.sync_later(window_start_date: Date.new(2026, 5, 2))
      assert_equal first.id, next_sync.predecessor_id
      assert_nil next_sync.parent_id
      assert_equal first.account_inputs_digest, next_sync.account_inputs_digest
      assert_not_equal first.account_sync_inputs.sole.id, next_sync.account_sync_inputs.sole.id
      assert_equal @handoff.payload, next_sync.account_sync_inputs.sole.payload
      assert_equal original, first.reload.attributes
      assert_equal next_sync.id, @account.sync_later(window_start_date: Date.new(2026, 5, 2)).id
    end
  end

  test "another provider parent receives its own sealed child and waits for the existing account calculation" do
    with_account_input do
      first = @account.sync_later
      first.start!
      child = enqueue_account_handoff
      assert_equal first.id, child.predecessor_id
      assert_equal @provider_sync.id, child.parent_id
      assert_nil first.parent_id
      assert_empty first.account_sync_inputs
    end
  end

  test "ad hoc calculations after completion retain the explicitly selected export despite newer unrelated batches" do
    with_account_input do
      first = enqueue_account_handoff
      first.start!
      first.complete!
      create_provider_batch(@connection, stream: "accounts", payload: { "unrelated" => "new export must not be selected" })
      next_sync = @account.sync_later
      assert_nil next_sync.predecessor_id
      assert_equal first.account_inputs_digest, next_sync.account_inputs_digest
      assert_equal @handoff.payload, next_sync.account_sync_inputs.sole.payload
    end
  end

  test "bulk writes cannot mutate a sealed window predecessor payload or materialization marker" do
    with_account_input do
      sync = enqueue_account_handoff
      input = sync.account_sync_inputs.sole
      [ { window_start_date: Date.new(2020, 1, 1) }, { predecessor_id: SecureRandom.uuid }, { account_inputs_digest: "changed" } ].each do |changes|
        assert_raises(ActiveRecord::StatementInvalid) do
          Sync.transaction(requires_new: true) { Sync.where(id: sync.id).update_all(changes) }
        end
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        Account::SyncInput.transaction(requires_new: true) { Account::SyncInput.where(id: input.id).update_all(payload_digest: "b" * 64) }
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        Account::SyncInput.transaction(requires_new: true) { Account::SyncInput.where(id: input.id).delete_all }
      end
      sync.update!(account_materialized_at: Time.current)
      assert_raises(ActiveRecord::StatementInvalid) do
        Sync.transaction(requires_new: true) { Sync.where(id: sync.id).update_all(account_materialized_at: nil) }
      end
      extra = input.dup
      assert_raises(ActiveRecord::StatementInvalid) { extra.save!(validate: false) }
    end
  end

  test "retry copies its failed calculation inputs even after a different source has been selected" do
    with_account_input do
      first = enqueue_account_handoff
      first.start!
      first.fail!
      @connection.update!(writer_epoch: 2)
      # An inventory without a captured grant cannot cross worker epochs. Use
      # the replacement run's actual export instead of recapturing the old one.
      @provider_sync = @connection.syncs.create!
      scope = Provider::AccountData::Ibkr::Archive.build(connection: @connection, sync: @provider_sync,
        observed_at: @provider_sync.created_at).fetch(:scope)
      reader = Provider::AccountData::Ibkr.new(client: nil, timezone: scope.fetch("timezone"), observed_at: @provider_sync.created_at,
        export_scope: scope, staged_xml: file_fixture("ibkr/flex_statement.xml").read)
      @inventory = create_provider_batch(@connection, sync: @provider_sync, payload: Ingestion::Codec.dump(reader.list_accounts))
      @handoff = capture_account_handoff
      replacement = enqueue_account_handoff
      retry_sync = first.retry_account_later
      assert_equal first.account_inputs_digest, retry_sync.account_inputs_digest
      assert_not_equal replacement.account_inputs_digest, retry_sync.account_inputs_digest
      assert_equal replacement.id, retry_sync.predecessor_id
      assert_raises(Provider::AccountData::StaleWriter) { retry_sync.account_sync_inputs.sole.resolve! }
    end
  end

  test "finalizing a predecessor schedules its already sealed successor" do
    with_account_input do
      first = enqueue_account_handoff
      first.start!
      successor = @account.sync_later
      assert_enqueued_with(job: SyncJob, args: [ successor ]) { first.complete! }
      assert successor.reload.pending?
    end
  end

  test "a different family's account cannot receive a handoff" do
    with_account_input do
      assert_no_difference "Account::SyncInput.count" do
        assert_raises(Provider::AccountData::InvalidResponse) do
          Account::SyncQueue.new(accounts(:investment)).enqueue(handoff: @handoff)
        end
      end
    end
  end

  test "input insertion pins the referenced provider sync before taking the account lock" do
    with_account_input do
      enqueue_account_handoff.start!
      locks = []
      subscriber = ->(event) do
        sql = event.payload.fetch(:sql)
        locks << sql if sql.include?("FOR KEY SHARE") || sql.include?("FOR UPDATE")
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { @account.sync_later }
      provider_lock = locks.index { |sql| sql.include?('FROM "syncs"') && sql.include?("FOR KEY SHARE") }
      account_lock = locks.index { |sql| sql.include?('FROM "accounts"') && sql.include?("FOR UPDATE") }
      assert provider_lock
      assert account_lock
      assert_operator provider_lock, :<, account_lock
    end
  end

  test "cancellation before handoff persistence cannot create a late account child" do
    with_account_input do
      @provider_sync.request_cancel!
      assert_no_difference "Account::SyncInput.count" do
        result = Provider::AccountData::Ibkr::AccountHandoff.new(connection: @connection, sync: @provider_sync,
          external_account: @external, writer_epoch: @connection.writer_epoch,
          fence: ->(&block) { @connection.with_lock(&block) }).enqueue!
        assert_nil result
      end
      assert_empty @provider_sync.children
    end
  end

  test "a pending-deletion owner rejects a real handoff before reading its captured payload" do
    with_account_input do
      Account.where(id: @account.id).update_all(status: "pending_deletion")
      Provider::AccountData::Ibkr::EquityHandoff.any_instance.expects(:payload).never
      clear_enqueued_jobs

      assert_no_difference [ "Sync.count", "Account::SyncInput.count", "Account::SyncSource.count" ] do
        assert_no_enqueued_jobs do
          assert_raises(Account::SyncAdmission::Unavailable) { enqueue_account_handoff }
        end
      end
      assert_empty @provider_sync.children
    end
  end

  test "an unavailable owner cannot read or copy its selected account input" do
    with_account_input do
      original = enqueue_account_handoff
      sync_before = original.reload.attributes
      source = Account::SyncSource.find_by!(account: @account)
      source_before = source.attributes
      input_id = original.account_sync_inputs.sole.id
      Account.where(id: @account.id).update_all(status: "pending_deletion")
      Account::SyncInput.any_instance.expects(:payload).never
      clear_enqueued_jobs

      assert_no_difference [ "Sync.count", "Account::SyncInput.count", "Account::SyncSource.count" ] do
        assert_no_enqueued_jobs do
          assert_raises(Account::SyncAdmission::Unavailable) { @account.sync_later(window_start_date: Date.new(2026, 5, 2)) }
        end
      end
      assert_equal sync_before, original.reload.attributes
      assert_equal source_before, source.reload.attributes
      assert_equal [ input_id ], original.account_sync_inputs.pluck(:id)
    end
  end

  test "retrying a finalized calculation refuses an unavailable owner before verifying original payloads" do
    with_account_input do
      original = enqueue_account_handoff
      original.start!
      original.fail!
      sync_before = original.reload.attributes
      input_id = original.account_sync_inputs.sole.id
      Account.where(id: @account.id).update_all(status: "pending_deletion")
      Account::SyncInput.any_instance.expects(:payload).never
      clear_enqueued_jobs

      assert_no_difference [ "Sync.count", "Account::SyncInput.count", "Account::SyncSource.count" ] do
        assert_no_enqueued_jobs do
          assert_raises(Account::SyncAdmission::Unavailable) { original.retry_account_later }
        end
      end
      assert_equal sync_before, original.reload.attributes
      assert_equal [ input_id ], original.account_sync_inputs.pluck(:id)
    end
  end
end
