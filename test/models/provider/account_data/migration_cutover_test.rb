require "test_helper"
require "timeout"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::MigrationCutoverTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Cutover = Provider::AccountData::MigrationCutover
  Preparation = Provider::AccountData::MigrationPreparation
  Copier = Provider::AccountData::MigrationCopier
  Fence = Provider::AccountData::LegacyWriterFence
  Evidence = Ingestion::LegacyIdentityEvidence

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::Up.expects(:new).never
  end

  test "verified Up cutover preserves financial bytes and installs only missing source selections" do
    with_cutover_source(select_policy: false) do |context|
      entry = identity_entry(context, external_id: "up_cutover-original", user_modified: true,
        extra: { "up" => { "pending" => false }, "retained_note" => "User-owned metadata" })
      financial = identity_financial_snapshot(context)
      link = context.link.reload.attributes
      assert_empty Account::SourcePolicy.where(account_id: context.account.id)

      finish_preparation(context)

      assert_equal financial, identity_financial_snapshot(context)
      policies = Account::SourcePolicy.where(account_id: context.account.id).order(:resource).map(&:attributes)
      assert_equal %w[balances transactions], policies.map { |row| row.fetch("resource") }
      assert policies.all? { |row| row.fetch("account_provider_id") == context.link.id && row.fetch("active") }
      original_evidence = retained_evidence(context)
      auxiliary = context.control.provider_connection.provider_sync_checkpoints.find_by!(stream: "legacy_logo_auxiliary")
      assert_equal "complete", auxiliary.state.fetch("phase")
      assert_equal 0, auxiliary.state.fetch("chunks")
      result = nil

      queries = capture_sql_queries do
        assert_enqueued_with(job: SyncJob) { result = command(context).call }
      end

      assert_equal context.control.id, result.control_id
      assert_equal context.control.provider_connection_id, result.connection_id
      refute result.replayed
      assert_active(context, result)
      assert_no_financial_sql(queries)
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal link, context.link.reload.attributes
      assert_equal policies, Account::SourcePolicy.where(account_id: context.account.id).order(:resource).map(&:attributes)
      assert_equal original_evidence, retained_evidence(context)
      assert_equal entry.id, EntrySource.where(bootstrap_external_account: context.external).sole.entry_identity
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(context.item) { flunk "Legacy ownership must be revoked" } }
    end
  end

  test "existing resource choices survive preparation and cutover" do
    with_cutover_source do |context|
      other_connection = create_provider_connection(family: context.family, provider_key: "mercury")
      other_external = create_external_account(other_connection)
      other_link = AccountProvider.create!(account: context.account, external_account: other_external,
        family: context.family, provider_key: "mercury")
      begin
        balance_policy = Account::SourcePolicy.select!(account: context.account, account_provider: other_link, resource: "balances")
        transaction_policy = Account::SourcePolicy.active.find_by!(account_id: context.account.id, resource: "transactions")
        before = Account::SourcePolicy.where(account_id: context.account.id).order(:id).map(&:attributes)

        finish_preparation(context)
        result = command(context).call

        assert_active(context, result)
        assert_equal before, Account::SourcePolicy.where(account_id: context.account.id).order(:id).map(&:attributes)
        assert balance_policy.reload.active?
        assert transaction_policy.reload.active?
      ensure
        Account::SourcePolicy.where(account_provider_id: other_link.id).delete_all
        other_link.delete
        other_connection.destroy!
      end
    end
  end

  test "cutover installs each account history floor without widening siblings through a global Sync window" do
    with_cutover_source do |context|
      item_start = Date.new(2020, 1, 2)
      account_start = Date.new(2024, 3, 4)
      context.item.update!(sync_start_date: item_start)
      context.source.update!(sync_start_date: account_start)
      sibling = context.item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Item-default history",
        currency: "USD", current_balance: 5, raw_transactions_payload: [])
      financial = identity_financial_snapshot(context)
      # Establish a new genuine copy before preparation has any identity/input
      # progress. Both old archive versions remain retained by the real copier.
      context.copier.run_quiesced(restart: true)
      20.times do
        break if context.control.reload.high_water_mark["phase"] == "verified"
        context.copier.run_quiesced
      end
      assert_equal "verified", context.control.reload.high_water_mark["phase"]
      sibling_external = context.control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: sibling.id).external_account
      expected = { context.external.id => account_start.iso8601, sibling_external.id => item_start.iso8601 }
      finish_preparation(context)

      result = command(context).call

      assert_active(context, result, account_starts: expected)
      assert_equal financial, identity_financial_snapshot(context)
      assert_nil sibling_external.reload.current_account
    end
  end

  test "missing foreign and invalid first-read boundaries roll back before ownership changes" do
    with_cutover_source do |context|
      finish_preparation(context)
      owner_before = ownership_snapshot(context)
      external_before = context.external.reload.attributes
      history = Provider::AccountData::Up::CutoverHistory
      boundaries = [ {}, { SecureRandom.uuid => Date.current }, { 1 => Date.current },
        { context.external.id => nil }, { context.external.id => "2020-01-02" },
        { context.external.id => Time.current } ]

      boundaries.each do |starts|
        history.any_instance.stubs(:verify!).returns(history::Result.new(account_starts: starts))
        assert_no_enqueued_jobs { assert_raises(Cutover::Conflict) { command(context).call } }
        assert_equal owner_before, ownership_snapshot(context)
        assert_equal external_before, context.external.reload.attributes
      end
    ensure
      history&.any_instance&.unstub(:verify!)
    end
  end

  test "pending replay dispatches the original Sync after the activation transaction and exclusive permit release" do
    with_cutover_source do |context|
      identity_entry(context, external_id: "up_cutover-handoff")
      finish_preparation(context)
      delivered = []
      dispatch = lambda do |sync|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        delivered << sync.id
        on_another_session do
          Fence.with_exclusive(context.item) do
            ProviderConnection.transaction do
              connection = ProviderConnection.lock("FOR UPDATE NOWAIT").find(context.control.provider_connection_id)
              assert connection.good?
              assert connection.provider_migration_control.active?
              assert_equal sync.id, connection.syncs.sole.id
              assert Sync.find(sync.id).pending?
            end
          end
        end
        nil
      end
      first = second = nil

      SyncJob.stub(:perform_later, dispatch) do
        first = command(context).call
        second = command(context).call
      end

      refute first.replayed
      assert second.replayed
      assert_equal first.sync_id, second.sync_id
      assert_equal [ first.sync_id, first.sync_id ], delivered
      assert_active(context, second)
    end
  end

  test "multiple links require an explicit missing resource choice before preparation can finish" do
    with_cutover_source do |context|
      other_connection = create_provider_connection(family: context.family, provider_key: "mercury")
      other_external = create_external_account(other_connection)
      other_link = AccountProvider.create!(account: context.account, external_account: other_external,
        family: context.family, provider_key: "mercury")
      begin
        original = Account::SourcePolicy.where(account_id: context.account.id).order(:id).map(&:attributes)
        assert_equal [ "transactions" ], original.map { |row| row.fetch("resource") }

        assert_no_enqueued_jobs do
          assert_raises(Provider::AccountData::Up::SourceSelection::Conflict) { finish_preparation(context) }
          assert_raises(Cutover::Conflict) { command(context).call }
        end

        assert_equal original, Account::SourcePolicy.where(account_id: context.account.id).order(:id).map(&:attributes)
        assert_empty SourceRecord.where(external_account: context.external)
        assert_paused(context)
      ensure
        other_link.delete
        other_connection.destroy!
      end
    end
  end

  test "queue failure retains one installed Sync for an ID-preserving retry" do
    with_cutover_source do |context|
      finish_preparation(context)
      failure = ->(*) { raise IOError, "Queue unavailable" }
      assert_raises(IOError) { SyncJob.stub(:perform_later, failure) { command(context).call } }
      original = context.control.provider_connection.syncs.sole
      assert original.pending?
      assert context.control.reload.active?

      result = nil
      assert_enqueued_with(job: SyncJob, args: [ original ]) { result = command(context).call }

      assert result.replayed
      assert_equal original.id, result.sync_id
      assert_active(context, result)
    end
  end

  test "direct Plaid or SimpleFIN ownership prevents defaults for a sole Up AccountProvider" do
    %i[plaid_account_id simplefin_account_id].each do |column|
      with_cutover_source(select_policy: false) do |context|
        direct_item = direct_source = nil
        begin
          if column == :plaid_account_id
            direct_item = PlaidItem.create!(family: context.family, name: "Direct Plaid ownership",
              access_token: "private-direct-plaid-token", plaid_id: SecureRandom.uuid, plaid_region: "eu")
            direct_source = direct_item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Direct checking",
              plaid_type: "depository", currency: "USD", current_balance: 10)
          else
            direct_item = SimplefinItem.create!(family: context.family, name: "Direct SimpleFIN ownership",
              access_url: "https://example.com/private-direct-simplefin")
            direct_source = direct_item.simplefin_accounts.create!(account_id: SecureRandom.uuid, name: "Direct checking",
              account_type: "checking", currency: "USD", current_balance: 10)
          end
          context.account.update_columns(column => direct_source.id)
          financial = identity_financial_snapshot(context)
          assert_equal [ context.link.id ], AccountProvider.where(account_id: context.account.id).pluck(:id)
          assert_nil direct_source.account_provider
          assert_empty Account::SourcePolicy.where(account_id: context.account.id)

          assert_no_enqueued_jobs do
            assert_raises(Provider::AccountData::Up::SourceSelection::Conflict) { finish_preparation(context) }
            assert_raises(Cutover::Conflict) { command(context).call }
          end

          assert_empty Account::SourcePolicy.where(account_id: context.account.id)
          assert_empty SourceRecord.where(external_account: context.external)
          assert_equal financial, identity_financial_snapshot(context)
          assert_paused(context)
        ensure
          context.account.update_columns(column => nil)
          direct_source&.delete
          direct_item&.delete # No remote disconnect callback belongs to this fixture cleanup.
        end
      end
    end
  end

  test "replay retains the original run after native epoch advance and never dispatches a completed run" do
    with_cutover_source do |context|
      finish_preparation(context)
      first = command(context).call
      connection = context.control.provider_connection
      original = connection.syncs.sole
      connection.update!(writer_epoch: 2)
      clear_enqueued_jobs

      pending = nil
      assert_enqueued_with(job: SyncJob, args: [ original ]) { pending = command(context).call }

      assert pending.replayed
      assert_equal first.sync_id, pending.sync_id
      assert_equal 2, connection.reload.writer_epoch
      assert_equal 1, context.control.reload.writer_epoch
      original.update!(status: "completed", completed_at: Time.current)
      clear_enqueued_jobs
      completed = nil

      assert_no_enqueued_jobs { completed = command(context).call }

      assert completed.replayed
      assert_equal first.sync_id, completed.sync_id
      assert_equal [ first.sync_id ], connection.syncs.pluck(:id)
      assert_equal 2, connection.reload.writer_epoch
      assert original.reload.completed?
    end
  end

  test "a verified copy alone cannot replace completed migration preparation" do
    with_cutover_source do |context|
      before = ownership_snapshot(context)
      assert_no_enqueued_jobs do
        assert_raises(Cutover::Conflict) { command(context).call }
      end
      assert_equal before, ownership_snapshot(context)
      assert_paused(context)
    end
  end

  test "wrong family and unsupported provider cannot alter prepared Up ownership" do
    with_cutover_source do |context|
      finish_preparation(context)
      before = ownership_snapshot(context)

      assert_no_enqueued_jobs do
        assert_raises(Cutover::Conflict) { command(context, family: families(:empty)).call }
        assert_raises(Cutover::Conflict) { command(context, provider_key: "wise").call }
      end

      assert_equal before, ownership_snapshot(context)
      assert_paused(context)
    end
  end

  test "transitional controls cannot use an old acceptance report to activate" do
    %w[shadow rollback_pending failed].each do |state|
      with_cutover_source do |context|
        finish_preparation(context)
        context.control.update!(state: state)
        before = ownership_snapshot(context)

        assert_no_enqueued_jobs { assert_raises(Cutover::Conflict) { command(context).call } }

        assert_equal before, ownership_snapshot(context)
        assert context.control.provider_connection.reload.disabled?
        assert_empty context.control.provider_connection.syncs
      end
    end
  end

  test "changed copied source after awaiting acceptance fails fresh verification without activation" do
    with_cutover_source do |context|
      identity_entry(context, external_id: "up_cutover-copy-drift")
      finish_preparation(context)
      context.source.update!(name: "Changed since copy")
      financial = identity_financial_snapshot(context)
      original_evidence = retained_evidence(context)

      assert_no_enqueued_jobs do
        assert_raises(Copier::SourceChanged, Copier::Conflict, Preparation::Conflict, Cutover::Conflict) { command(context).call }
      end

      assert_paused(context)
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal original_evidence, retained_evidence(context)
    end
  end

  test "changed financial identity after awaiting acceptance refuses the old proof" do
    with_cutover_source do |context|
      entry = identity_entry(context, external_id: "up_cutover-old-identity")
      finish_preparation(context)
      entry.update_columns(external_id: "up_cutover-changed-identity")
      financial = identity_financial_snapshot(context)
      original_evidence = retained_evidence(context)

      assert_no_enqueued_jobs do
        assert_raises(Evidence::InvalidEvidence, Preparation::Conflict, Cutover::Conflict) { command(context).call }
      end

      assert_paused(context)
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal original_evidence, retained_evidence(context)
    end
  end

  test "pending or running legacy work blocks cutover rather than being silently discarded" do
    %w[pending syncing].each do |status|
      with_cutover_source do |context|
        finish_preparation(context)
        legacy_sync = context.item.syncs.create!(status: status)
        before = legacy_sync.attributes

        assert_no_enqueued_jobs { assert_raises(Cutover::Conflict) { command(context).call } }

        assert_paused(context)
        assert_equal before, legacy_sync.reload.attributes
      end
    end
  end

  test "Sync creation failure rolls back ownership epochs and dispatch atomically" do
    with_cutover_source do |context|
      identity_entry(context, external_id: "up_cutover-rollback")
      finish_preparation(context)
      financial = identity_financial_snapshot(context)
      external_attributes = context.external.reload.attributes
      connection_id = context.control.provider_connection_id
      fail_sync = lambda do
        raise "Forced cutover Sync failure" if syncable_type == "ProviderConnection" && syncable_id == connection_id
      end
      Sync.set_callback(:create, :before, fail_sync)
      begin
        assert_no_enqueued_jobs do
          error = assert_raises(RuntimeError) { command(context).call }
          assert_equal "Forced cutover Sync failure", error.message
        end

        assert_paused(context)
        assert_equal financial, identity_financial_snapshot(context)
        assert_equal external_attributes, context.external.reload.attributes
      ensure
        Sync.skip_callback(:create, :before, fail_sync)
      end

      result = command(context).call
      refute result.replayed
      assert_active(context, result)
    end
  end

  test "cutover refusal diagnostics do not expose provider token or cached financial payload" do
    with_cutover_source do |context|
      finish_preparation(context)
      secret = "private-cutover-cached-payload"
      context.source.update!(raw_transactions_payload: [ { "private_note" => secret } ])
      diagnostics = []
      capture = ->(**attributes) { diagnostics << attributes.except(:family, :account_provider, :account) }

      DebugLogEntry.stub(:capture, capture) do
        assert_no_enqueued_jobs do
          error = assert_raises(Copier::SourceChanged, Copier::Conflict, Preparation::Conflict, Cutover::Conflict) { command(context).call }
          refute_includes error.message, context.item.access_token
          refute_includes error.message, secret
        end
      end

      refute_includes diagnostics.to_json, context.item.access_token
      refute_includes diagnostics.to_json, secret
      assert_paused(context)
    end
  end

  private
    def command(context, **options)
      Cutover.new(**{ provider_key: "up", legacy_item_id: context.item.id, family: context.family, page_size: 1 }.merge(options))
    end

    def finish_preparation(context)
      150.times do
        result = Preparation.new(provider_key: "up", legacy_item_id: context.item.id, family: context.family, page_size: 1).run
        return result if result.awaiting_acceptance?
      end
      flunk "Preparation did not complete its bounded verification calls"
    end

    def with_cutover_source(select_policy: true)
      family = families(:dylan_family)
      timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
      with_identity_source do |context|
        begin
          Account::SourcePolicy.where(account_id: context.account.id).delete_all unless select_policy
          yield context
        ensure
          # Only this fixture's jobs are removed; retained archive rows are
          # removed by IdentityBootstrapTestHelper before its connection owner.
          connection = ProviderConnection.find_by(id: context.control.provider_connection_id)
          connection&.update_columns(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil)
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all if connection
          Sync.where(syncable_type: context.item.class.base_class.name, syncable_id: context.item.id).delete_all
        end
      end
    ensure
      family&.update_columns(timestamps) if timestamps
      clear_enqueued_jobs
    end

    def assert_active(context, result, account_starts: nil)
      control = context.control.reload
      connection = control.provider_connection.reload
      assert control.active?
      assert connection.good?
      assert_equal 1, control.writer_epoch
      assert_equal 1, connection.writer_epoch
      assert_nil control.lease_owner
      assert_nil connection.lease_owner
      assert_nil connection.lease_sync_id
      sync = connection.syncs.sole
      assert_equal result.sync_id, sync.id
      assert sync.pending?
      assert_equal "ProviderConnection", sync.syncable_type
      assert_equal connection.id, sync.syncable_id
      assert_nil sync.window_start_date
      assert_nil sync.window_end_date
      receipt = control.audit_results.fetch("native_cutover")
      assert_equal Cutover::FORMAT, receipt.fetch("format")
      assert_equal control.preparation_state.fetch("run_id"), receipt.fetch("preparation_run_id")
      assert_equal control.high_water_mark.fetch("copy_run_id"), receipt.fetch("copy_run_id")
      assert_equal [ connection.id, sync.id, 1 ], receipt.values_at("connection_id", "sync_id", "writer_epoch")
      account_starts ||= { context.external.id => (Date.current - 90.days).iso8601 }
      assert_equal account_starts, receipt.fetch("account_starts")
      actual_starts = connection.external_accounts.to_h { |external| [ external.id, external.metadata.fetch("up_initial_history_start") ] }
      assert_equal account_starts, actual_starts
    end

    def assert_paused(context)
      assert context.control.reload.quiescing?
      connection = context.control.provider_connection.reload
      assert connection.disabled?
      assert_equal 0, context.control.writer_epoch
      assert_equal 0, connection.writer_epoch
      assert_empty connection.syncs
    end

    def ownership_snapshot(context)
      { control: context.control.reload.attributes, connection: context.control.provider_connection.reload.attributes,
        syncs: context.control.provider_connection.syncs.order(:id).map(&:attributes) }
    end

    def retained_evidence(context)
      batches = context.control.provider_connection.ingestion_batches.order(:id)
      { ciphertexts: batches.pluck(:id, Arel.sql("payload::text")),
        observations: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        mappings: EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes) }
    end

    def on_another_session
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      outcome = Queue.new
      key_provider = ActiveRecord::Encryption.key_provider
      worker = Thread.new do
        ActiveRecord::Encryption.with_encryption_context(key_provider: key_provider) do
          ApplicationRecord.connection_pool.with_connection { outcome << [ :ok, yield ] }
        end
      rescue Exception => error # Preserve assertions as well as admission failures across the thread.
        outcome << [ :error, error ]
      end
      status, value = Timeout.timeout(5) { outcome.pop }
      raise value if status == :error
      value
    ensure
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
end
