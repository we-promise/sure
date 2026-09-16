require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::SyncerTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
  end

  test "an eligible busy connection defers without building credentials touching its lease or calling the adapter" do
    with_provider_encryption do
      freeze_time do
        [ 5.seconds, 2.minutes ].each do |remaining|
          connection = create_provider_connection(lease_owner: "existing-worker", lease_expires_at: remaining.from_now, writer_epoch: 7)
          before = connection.attributes.slice("lease_owner", "lease_expires_at", "writer_epoch", "updated_at")
          adapter = mock("successor must wait")
          adapter.expects(:list_accounts).never
          Provider::AccountData::Registry.expects(:build).never
          Provider::AccountData::CredentialStore.expects(:new).never
          DebugLogEntry.expects(:capture).never
          error = assert_raises(Provider::AccountData::DeferredPage) do
            Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
          end
          assert_equal [ remaining, 15.seconds ].min.from_now, error.resume_at
          assert_equal before, connection.reload.attributes.slice("lease_owner", "lease_expires_at", "writer_epoch", "updated_at")
          assert_empty connection.ingestion_batches
        end
      end
    end
  end

  test "only a completed page chain advances its durable checkpoint" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      first_page = account_page("account-1", complete: false, next_cursor: "page-2")
      adapter = mock("interrupted adapter")
      adapter.expects(:list_accounts).with(cursor: nil).returns(first_page)
      adapter.expects(:list_accounts).with(cursor: "page-2").raises(Provider::AccountData::InvalidResponse, "Provider unavailable")

      assert_raises(Provider::AccountData::InvalidResponse) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
      end

      assert_equal [ "account-1" ], connection.external_accounts.pluck(:external_id)
      assert_equal 1, connection.ingestion_batches.where(status: "applied").count
      assert_empty connection.provider_sync_checkpoints
      assert_nil connection.reload.lease_owner

      resumed = mock("resumed adapter")
      resumed.expects(:list_accounts).with(cursor: "page-2")
        .returns(account_page("account-2", checkpoint_cursor: "durable-cursor"))
      Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(sync)

      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "accounts")
      assert_equal "durable-cursor", checkpoint.cursor
      assert checkpoint.ingestion_batch.applied?
      assert_equal [ "account-1", "account-2" ], connection.external_accounts.order(:external_id).pluck(:external_id)
      assert_equal 2, connection.ingestion_batches.count

      replayed = mock("replayed adapter")
      replayed.expects(:list_accounts).never
      assert_no_difference [ "ExternalAccount.count", "IngestionBatch.count", "ProviderSyncCheckpoint.count" ] do
        Provider::AccountData::Syncer.new(connection, adapter: replayed).perform_sync(sync)
      end
      assert_equal checkpoint.id, connection.provider_sync_checkpoints.find_by!(stream: "accounts").id
    end
  end

  test "an incomplete terminal response retains data without advancing the checkpoint" do
    with_provider_encryption do
      connection = create_provider_connection
      adapter = mock("incomplete adapter")
      adapter.expects(:list_accounts).with(cursor: nil).returns(account_page("account-1", complete: false))

      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end

      assert_equal 1, connection.external_accounts.count
      assert_equal 1, connection.ingestion_batches.count
      assert_empty connection.provider_sync_checkpoints
    end
  end

  test "an old partial run cannot apply after a newer run has completed the resource" do
    with_provider_encryption do
      connection = create_provider_connection
      old_sync = connection.syncs.create!
      interrupted = mock("older adapter")
      interrupted.expects(:list_accounts).with(cursor: nil)
        .returns(account_page("old-first-page", complete: false, next_cursor: "old-page-2"))
      interrupted.expects(:list_accounts).with(cursor: "old-page-2")
        .raises(Provider::AccountData::InvalidResponse, "Provider unavailable")
      assert_raises(Provider::AccountData::InvalidResponse) do
        Provider::AccountData::Syncer.new(connection, adapter: interrupted).perform_sync(old_sync)
      end

      newer = mock("newer adapter")
      newer.expects(:list_accounts).with(cursor: nil).returns(account_page("newer-account", checkpoint_cursor: "newer-checkpoint"))
      Provider::AccountData::Syncer.new(connection, adapter: newer).perform_sync(connection.syncs.create!)
      newer_checkpoint_batch = connection.provider_sync_checkpoints.find_by!(stream: "accounts").ingestion_batch_id

      resumed = mock("old run retry")
      resumed.expects(:list_accounts).with(cursor: "old-page-2").returns(account_page("stale-account"))
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(old_sync)
      end

      assert_not connection.external_accounts.exists?(external_id: "stale-account")
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "accounts")
      assert_equal "newer-checkpoint", checkpoint.cursor
      assert_equal newer_checkpoint_batch, checkpoint.ingestion_batch_id
      assert connection.ingestion_batches.find_by!(sync: old_sync, sequence: 1).captured?
    end
  end

  test "repeating continuation cursors cannot falsely complete a stream" do
    with_provider_encryption do
      connection = create_provider_connection
      adapter = mock("repeating adapter")
      adapter.expects(:list_accounts).with(cursor: nil).returns(account_page("account-1", complete: false, next_cursor: "same-page"))
      adapter.expects(:list_accounts).with(cursor: "same-page").returns(account_page("account-2", complete: false, next_cursor: "same-page"))

      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end

      assert_empty connection.provider_sync_checkpoints
      assert_equal 2, connection.external_accounts.count
    end
  end

  test "a new worker invalidates a response fetched by the previous lease owner" do
    with_provider_encryption do
      connection = create_provider_connection
      adapter = stub
      adapter.define_singleton_method(:list_accounts) do |cursor:|
        replacement = ProviderConnection.find(connection.id)
        replacement.update!(writer_epoch: replacement.writer_epoch + 1, lease_owner: "replacement-worker", lease_expires_at: 10.minutes.from_now)
        Provider::AccountData::Page.new(records: [], complete: true)
      end

      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end

      assert_empty connection.ingestion_batches
      assert_empty connection.provider_sync_checkpoints
      assert_equal "replacement-worker", connection.reload.lease_owner
    end
  end

  test "an ineligible connection still fails even when another lease exists" do
    with_provider_encryption do
      connection = create_provider_connection(status: "disabled", lease_owner: "existing-worker", lease_expires_at: 10.minutes.from_now)
      adapter = mock("unused adapter")
      adapter.expects(:list_accounts).never

      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end

      assert_equal "existing-worker", connection.reload.lease_owner
    end
  end

  test "migration rollback fences an in-flight source response" do
    with_provider_encryption do
      connection = create_provider_connection
      control = ProviderMigrationControl.create!(
        family: connection.family, provider_connection: connection, provider_key: "up",
        legacy_type: "UpItem", legacy_id: SecureRandom.uuid, state: "active"
      )
      adapter = stub
      adapter.define_singleton_method(:list_accounts) do |cursor:|
        control.update!(state: "rollback_pending")
        Provider::AccountData::Page.new(records: [], complete: true)
      end

      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end

      assert_empty connection.ingestion_batches
      assert_empty connection.provider_sync_checkpoints
    end
  end

  test "retiring legacy compatibility data preserves native ingestion ownership" do
    with_provider_encryption do
      connection = create_provider_connection
      ProviderMigrationControl.create!(family: connection.family, provider_connection: connection,
        provider_key: "up", legacy_type: "UpItem", legacy_id: SecureRandom.uuid, state: "retired")
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).with(cursor: nil).returns(
        Provider::AccountData::Page.new(records: [], complete: true))

      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)

      assert connection.ingestion_batches.sole.applied?
      assert connection.provider_sync_checkpoints.find_by!(stream: "accounts").ingestion_batch.applied?
      assert_nil connection.reload.lease_owner
    end
  end

  test "account transaction writes evidence and checkpoints atomically and replay does not duplicate entries" do
    with_provider_encryption do
      connection, external, account = linked_connection
      adapter = transaction_adapter(external, records: [ transaction_record("shared-tx-1") ])
      sync = connection.syncs.create!

      assert_difference "account.entries.count", 1 do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
      end
      entry = account.entries.find_by!(external_id: "shared-tx-1", source: "up")
      observation = SourceRecord.find_by!(external_account: external, external_id: "shared-tx-1")
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "transactions", scope_key: "account:#{external.id}")
      assert_equal entry.id, observation.entry_source.entry_id
      assert_equal checkpoint.ingestion_batch_id, observation.ingestion_batch_id
      assert checkpoint.ingestion_batch.applied?

      replayed = mock("replayed adapter")
      replayed.expects(:list_accounts).never
      replayed.expects(:fetch_transactions).never
      replayed.stubs(:capabilities).returns([ "transactions" ])
      assert_no_difference [ "account.entries.count", "SourceRecord.count", "EntrySource.count", "IngestionBatch.count" ] do
        Provider::AccountData::Syncer.new(connection, adapter: replayed).perform_sync(sync)
      end
    end
  end

  test "one rejected record rolls back all ledger and evidence changes for its page" do
    with_provider_encryption do
      connection, external, account = linked_connection
      records = [ transaction_record("valid-first-record"), transaction_record("invalid-second-record", date: Date.new(1, 1, 1)) ]
      adapter = transaction_adapter(external, records: records)

      assert_no_difference [ "account.entries.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Provider::AccountData::Error) do
          Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
        end
      end

      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
      batch = connection.ingestion_batches.find_by!(stream: "transactions")
      assert batch.captured?
      assert_equal 2, Ingestion::Codec.load(batch.payload).records.length
    end
  end

  test "secondary providers retain evidence while only the selected source posts transactions" do
    with_provider_encryption do
      primary, primary_external, account = linked_connection
      secondary = create_provider_connection(provider_key: "plaid")
      secondary_external = create_external_account(secondary, external_id: "secondary-account")
      AccountProvider.create!(account: account, external_account: secondary_external)

      primary_adapter = transaction_adapter(primary_external, records: [ transaction_record("primary-transaction") ])
      secondary_adapter = transaction_adapter(secondary_external, records: [ transaction_record("secondary-transaction") ])
      Provider::AccountData::Syncer.new(primary, adapter: primary_adapter).perform_sync(primary.syncs.create!)

      assert_no_difference "account.entries.count" do
        Provider::AccountData::Syncer.new(secondary, adapter: secondary_adapter).perform_sync(secondary.syncs.create!)
      end

      observation = SourceRecord.find_by!(external_account: secondary_external, external_id: "secondary-transaction")
      assert_nil observation.entry_source
      assert observation.ingestion_batch.applied?
      assert_nil account.entries.find_by(external_id: "secondary-transaction")
      assert account.entries.find_by(external_id: "primary-transaction")
    end
  end

  test "source selection changes during fetching prevent applying the old result" do
    with_provider_encryption do
      connection, external, account = linked_connection
      secondary = create_provider_connection(provider_key: "plaid")
      other_external = create_external_account(secondary)
      other_link = AccountProvider.create!(account: account, external_account: other_external)
      records = [ transaction_record("stale-policy-transaction") ]
      accounts_page = account_page(external.external_id)
      adapter = stub
      adapter.stubs(:capabilities).returns([ "transactions" ])
      adapter.stubs(:fetch_balance).returns(accounts_page)
      adapter.define_singleton_method(:list_accounts) { |cursor:| accounts_page }
      adapter.define_singleton_method(:fetch_transactions) do |account:, cursor:, window:|
        Account::SourcePolicy.select!(account: other_link.account, account_provider: other_link, resource: "transactions")
        Provider::AccountData::Page.new(records: records, complete: true)
      end

      assert_no_difference [ "account.entries.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::Error) do
          Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
        end
      end

      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
      assert connection.ingestion_batches.find_by!(stream: "transactions").captured?
    end
  end

  test "a sync from another family cannot claim the connection" do
    with_provider_encryption do
      connection = create_provider_connection
      foreign_connection = create_provider_connection(family: families(:empty))
      adapter = mock("unused adapter")
      adapter.expects(:list_accounts).never

      assert_raises(Provider::AccountData::Error) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(foreign_connection.syncs.create!)
      end

      assert_equal 0, connection.reload.writer_epoch
      assert_empty connection.ingestion_batches
    end
  end

  test "balance refresh remains independent when the transaction endpoint fails" do
    with_provider_encryption do
      connection, external, account = linked_connection
      adapter = mock("unavailable transactions")
      adapter.stubs(:capabilities).returns([ "transactions" ])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      adapter.expects(:fetch_transactions).raises(Provider::AccountData::InvalidResponse, "Unavailable")
      record = Ingestion::Record.account(external_id: external.external_id, name: "Checking", currency: "EUR", balance: BigDecimal("987.65"))
      adapter.stubs(:fetch_balance).returns(Provider::AccountData::Page.new(records: [ record ], complete: true))

      assert_raises(Provider::AccountData::Error) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end

      assert_equal BigDecimal("987.65"), account.reload.balance
      assert_equal "EUR", account.currency
      assert connection.provider_sync_checkpoints.find_by!(stream: "balances").ingestion_batch.applied?
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
    end
  end

  test "discovery without balance or currency preserves existing observations" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection, currency: "GBP", current_balance: BigDecimal("75"))
      record = Ingestion::Record.account(external_id: external.external_id, name: "Discovered account", currency: nil,
        balance: nil, metadata: { balance_provided: false })
      adapter = mock("identity-only inventory")
      adapter.expects(:list_accounts).returns(Provider::AccountData::Page.new(records: [ record ], complete: true))

      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)

      assert_equal "GBP", external.reload.currency
      assert_equal BigDecimal("75"), external.current_balance
    end
  end

  test "committed partial progress resumes without claiming completed coverage" do
    with_provider_encryption do
      connection = create_provider_connection
      record = Ingestion::Record.account(external_id: "progress-account", name: "Checking", currency: "USD")
      page = Provider::AccountData::Page.new(records: [ record ], complete: false, progress_cursor: "history-progress")
      adapter = mock("bounded inventory")
      adapter.expects(:list_accounts).with(cursor: nil).returns(page)
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end

      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "accounts")
      assert_nil checkpoint.covered_through
      assert_nil checkpoint.cursor
      assert_nil checkpoint.ingestion_batch_id
      assert_equal "history-progress", checkpoint.state.dig("progress", "cursor")

      resumed = mock("resumed bounded inventory")
      resumed.expects(:list_accounts).with(cursor: "history-progress").returns(account_page("last-account", checkpoint_cursor: "completed"))
      Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(connection.syncs.create!)

      assert_equal "completed", checkpoint.reload.cursor
      assert checkpoint.covered_through
      assert checkpoint.ingestion_batch.applied?
      assert_nil checkpoint.state["progress"]
    end
  end

  test "a new sync restarts snapshot progress while preserving prior evidence until publication" do
    with_provider_encryption do
      connection = create_provider_connection
      completed = mock("previous completed snapshot")
      completed.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      completed.expects(:list_accounts).with(cursor: nil).returns(
        account_page("completed-account", checkpoint_cursor: "completed-before-snapshot"))
      Provider::AccountData::Syncer.new(connection, adapter: completed).perform_sync(connection.syncs.create!)
      checkpoint = connection.provider_sync_checkpoints.sole
      original_coverage = checkpoint.covered_through
      completed_batch_id = checkpoint.ingestion_batch_id
      original_sync = connection.syncs.create!
      interrupted = mock("snapshot interrupted")
      interrupted.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      interrupted.expects(:list_accounts).with(cursor: "completed-before-snapshot").returns(Provider::AccountData::Page.new(
        records: [], complete: false, progress_cursor: "original-snapshot-offset"))
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: interrupted).perform_sync(original_sync)
      end
      original_batch = connection.ingestion_batches.where(sync: original_sync).sole
      original_payload = original_batch.payload
      original_state = checkpoint.reload.state.deep_dup
      replacement_sync = connection.syncs.create!
      unavailable = mock("fresh snapshot unavailable")
      unavailable.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      unavailable.expects(:list_accounts).with(cursor: "completed-before-snapshot").raises(Provider::AccountData::InvalidResponse)
      assert_raises(Provider::AccountData::InvalidResponse) do
        Provider::AccountData::Syncer.new(connection, adapter: unavailable).perform_sync(replacement_sync)
      end
      assert_equal original_state, checkpoint.reload.state
      assert_equal original_coverage, checkpoint.covered_through
      assert_equal completed_batch_id, checkpoint.ingestion_batch_id
      assert_equal original_payload, original_batch.reload.payload
      assert_equal 2, connection.ingestion_batches.count

      fresh = mock("fresh snapshot ready")
      fresh.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      fresh.expects(:list_accounts).with(cursor: "completed-before-snapshot").returns(account_page("new-snapshot-account"))
      Provider::AccountData::Syncer.new(connection, adapter: fresh).perform_sync(replacement_sync)
      assert_nil checkpoint.reload.state["progress"]
      assert_equal replacement_sync.id, checkpoint.ingestion_batch.sync_id
      assert_equal original_payload, original_batch.reload.payload
      assert original_batch.applied?
      assert_equal 3, connection.ingestion_batches.count
    end
  end

  test "snapshot progress resumes in a later attempt of the same logical sync" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      waiting = mock("snapshot waiting")
      waiting.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      waiting.expects(:list_accounts).with(cursor: nil).returns(Provider::AccountData::Page.new(
        records: [], complete: false, progress_cursor: "same-snapshot-offset",
        coverage: { "available_at" => 10.seconds.from_now.iso8601 }))
      assert_raises(Provider::AccountData::DeferredPage) do
        Provider::AccountData::Syncer.new(connection, adapter: waiting).perform_sync(sync)
      end
      original_batch = connection.ingestion_batches.sole
      original_payload = original_batch.payload
      sync.update!(provider_attempt: 1)
      resumed = mock("same snapshot resumed")
      resumed.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      resumed.expects(:list_accounts).with(cursor: "same-snapshot-offset").returns(account_page("same-snapshot-account"))
      Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(sync)
      assert_nil connection.provider_sync_checkpoints.sole.state["progress"]
      assert_equal original_payload, original_batch.reload.payload
      assert_equal 2, connection.ingestion_batches.count
      assert_equal [ sync.id ], connection.ingestion_batches.distinct.pluck(:sync_id)
    end
  end

  test "snapshot progress never resets to hide a foreign progress batch" do
    with_provider_encryption do
      connection = create_provider_connection
      original_sync = connection.syncs.create!
      waiting = mock("snapshot waiting")
      waiting.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      waiting.expects(:list_accounts).returns(Provider::AccountData::Page.new(
        records: [], complete: false, progress_cursor: "snapshot-offset"))
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: waiting).perform_sync(original_sync)
      end
      foreign_connection = create_provider_connection
      foreign_batch = create_provider_batch(foreign_connection, status: "applied", applied_at: Time.current)
      checkpoint = connection.provider_sync_checkpoints.sole
      checkpoint.update_column(:state, { "progress" => { "cursor" => "foreign-offset", "ingestion_batch_id" => foreign_batch.id } })
      fresh = mock("invalid progress cannot issue HTTP")
      fresh.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:sync)
      fresh.expects(:list_accounts).never
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: fresh).perform_sync(connection.syncs.create!)
      end
      assert_equal foreign_batch.id, checkpoint.reload.state.dig("progress", "ingestion_batch_id")
    end
  end

  test "snapshot activity cursors resume within a sync and restart for the next sync" do
    with_provider_encryption do
      connection, external, account = linked_connection
      Account::SourcePolicy.select!(account: account, account_provider: external.account_provider, resource: "activities")
      sync = connection.syncs.create!
      first = mock("first activity snapshot page")
      first.stubs(:capabilities).returns([ "activities" ])
      first.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:connection)
      first.stubs(:progress_cursor_scope).with(stream: "balances").returns(:connection)
      first.stubs(:progress_cursor_scope).with(stream: "activities").returns(:sync)
      first.expects(:list_accounts).returns(account_page(external.external_id))
      first.expects(:fetch_balance).returns(account_page(external.external_id))
      first.expects(:fetch_activities).with { |arguments| arguments[:cursor].nil? }.returns(
        Provider::AccountData::Page.new(records: [], complete: false, progress_cursor: "snapshot-offset-100"))
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: first).perform_sync(sync)
      end
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "activities")
      assert_nil checkpoint.covered_through
      sync.update!(provider_attempt: 1)
      resumed = mock("second page of same activity snapshot")
      resumed.stubs(:capabilities).returns([ "activities" ])
      resumed.stubs(:progress_cursor_scope).with(stream: "activities").returns(:sync)
      resumed.expects(:list_accounts).never
      resumed.expects(:fetch_balance).never
      resumed.expects(:fetch_activities).with { |arguments| arguments[:cursor] == "snapshot-offset-100" }.returns(
        Provider::AccountData::Page.new(records: [], complete: false, progress_cursor: "snapshot-offset-200"))
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(sync)
      end
      assert_nil checkpoint.reload.covered_through
      original_batches = connection.ingestion_batches.where(sync: sync, stream: "activities").order(:created_at).to_a
      original_payloads = original_batches.map(&:payload)
      assert_equal 2, original_batches.size

      next_sync = connection.syncs.create!
      fresh = mock("fresh activity snapshot")
      fresh.stubs(:capabilities).returns([ "activities" ])
      fresh.stubs(:progress_cursor_scope).with(stream: "accounts").returns(:connection)
      fresh.stubs(:progress_cursor_scope).with(stream: "balances").returns(:connection)
      fresh.stubs(:progress_cursor_scope).with(stream: "activities").returns(:sync)
      fresh.expects(:list_accounts).returns(account_page(external.external_id))
      fresh.expects(:fetch_balance).returns(account_page(external.external_id))
      fresh.expects(:fetch_activities).with { |arguments| arguments[:cursor].nil? }.returns(
        Provider::AccountData::Page.new(records: [], complete: true))
      assert_no_difference [ "Entry.count", "Holding.count" ] do
        Provider::AccountData::Syncer.new(connection, adapter: fresh).perform_sync(next_sync)
      end
      assert_nil checkpoint.reload.state["progress"]
      assert_equal next_sync.id, checkpoint.ingestion_batch.sync_id
      assert_equal original_payloads, original_batches.map { |batch| batch.reload.payload }
    end
  end

  test "a new currency hint cannot relabel a cached monetary observation" do
    with_provider_encryption do
      connection, external, account = linked_connection
      external.update!(currency: "USD", current_balance: "75", cash_balance: "70")
      record = Ingestion::Record.account(external_id: external.external_id, name: "Changed currency", currency: "EUR",
        metadata: { balance_provided: false })
      adapter = mock("unvalued currency change")
      adapter.stubs(:capabilities).returns([])
      adapter.expects(:list_accounts).returns(Provider::AccountData::Page.new(records: [ record ], complete: true))
      adapter.expects(:fetch_balance).with { |arguments|
        arguments[:account][:currency] == "EUR" && arguments[:account][:balance].nil? &&
          arguments[:account][:cash_balance].nil? && arguments[:account][:metadata]["balance_snapshot_current"] == false
      }.raises(Provider::AccountData::IncompletePage)
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      assert_equal "USD", external.reload.currency
      assert_equal BigDecimal("75"), external.current_balance
      assert_equal BigDecimal("70"), external.cash_balance
      assert_equal "EUR", external.metadata.fetch("reported_currency")
      assert_equal "USD", account.reload.currency
    end
  end

  test "a valued currency change clears omitted balances from the previous unit" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection, currency: "USD", current_balance: "75", cash_balance: "70", available_balance: "74")
      record = Ingestion::Record.account(external_id: external.external_id, name: "Changed currency", currency: "EUR", balance: BigDecimal("65"))
      adapter = mock("valued currency change")
      adapter.expects(:list_accounts).returns(Provider::AccountData::Page.new(records: [ record ], complete: true))
      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      assert_equal "EUR", external.reload.currency
      assert_equal BigDecimal("65"), external.current_balance
      assert_nil external.cash_balance
      assert_nil external.available_balance
    end
  end

  test "resuming a snapshot cannot prune holds observed before its saved progress" do
    with_provider_encryption do
      connection, external, account = linked_connection
      held = Ingestion::Record.transaction(external_id: "held-before-progress", name: "Held purchase", currency: "USD",
        date: Date.current - 3, amount: BigDecimal("10"), pending: true)
      coverage = { "start" => 7.days.ago.utc.iso8601, "end" => Time.current.utc.iso8601 }
      first = mock("first snapshot segment")
      first.stubs(:capabilities).returns([ "transactions" ])
      first.expects(:list_accounts).returns(account_page(external.external_id))
      first.stubs(:fetch_balance).returns(account_page(external.external_id))
      first.expects(:fetch_transactions).returns(Provider::AccountData::Page.new(records: [ held ], complete: false,
        progress_cursor: "remaining-history", mode: "snapshot", coverage: coverage))
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: first).perform_sync(connection.syncs.create!)
      end

      resumed = mock("remaining snapshot segment")
      resumed.stubs(:capabilities).returns([ "transactions" ])
      resumed.expects(:list_accounts).returns(account_page(external.external_id))
      resumed.stubs(:fetch_balance).returns(account_page(external.external_id))
      resumed.expects(:fetch_transactions).with { |arguments| arguments[:cursor] == "remaining-history" }
        .returns(Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot", coverage: coverage))
      Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(connection.syncs.create!)

      assert account.entries.find_by!(external_id: "held-before-progress").transaction.pending?
      assert_nil connection.provider_sync_checkpoints.find_by!(stream: "transactions").state["progress"]
    end
  end

  test "connection-scoped transaction adapters use the shared generation barrier under the sync lease" do
    with_provider_encryption do
      connection, external, account = linked_connection
      adapter = stub("connection transaction adapter")
      adapter.stubs(:transaction_scope).returns(:connection)
      adapter.stubs(:capabilities).returns([ "transactions" ])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      adapter.stubs(:fetch_balance).returns(account_page(external.external_id))
      adapter.expects(:fetch_transactions).never
      partial = Provider::AccountData::Page.new(records: [ transaction_record("connection-scope-entry") ], complete: false, mode: "delta")
      account_id = external.external_id
      adapter.define_singleton_method(:fetch_transaction_group) do |generation_id:, start_cursor:, cursor:|
        Provider::AccountData::TransactionGroup.new(generation_id: generation_id, start_cursor: start_cursor, request_cursor: cursor,
          next_cursor: "connection-terminal", complete: true, account_pages: { account_id => partial }, unassigned_removed_ids: [], evidence: {})
      end
      sync = connection.syncs.create!
      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
      generation = connection.provider_sync_generations.sole
      assert generation.applied?
      assert_equal sync.id, generation.sync_id
      assert_equal generation.writer_epoch, generation.children.sole.writer_epoch
      assert_equal account.id, SourceRecord.find_by!(external_account: external, external_id: "connection-scope-entry").account_id
      cursor = connection.provider_sync_checkpoints.find_by!(stream: "transactions", scope_key: "connection")
      assert_equal "connection-terminal", cursor.cursor
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions", external_account: external)
      assert_nil connection.reload.lease_owner
    end
  end

  test "balance pagination can retain fetch progress before a complete monetary observation exists" do
    with_provider_encryption do
      connection, external, account = linked_connection
      external.update!(current_balance: "5000", cash_balance: "5000")
      pending = mock("partial portfolio valuation")
      pending.stubs(:capabilities).returns([])
      pending.expects(:list_accounts).returns(account_page(external.external_id))
      pending.expects(:fetch_balance).returns(Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot",
        progress_cursor: "remaining-portfolio-assets", coverage: { "end" => 2.days.ago.utc.iso8601 }))
      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: pending).perform_sync(connection.syncs.create!)
      end
      assert_equal BigDecimal("5000"), account.reload.balance
      assert_equal BigDecimal("5000"), external.reload.current_balance
      cursor = connection.provider_sync_checkpoints.find_by!(stream: "balances")
      assert_nil cursor.covered_through
      assert_nil cursor.cursor
      assert_equal "remaining-portfolio-assets", cursor.state.dig("progress", "cursor")
      assert connection.ingestion_batches.find_by!(stream: "balances").applied?

      observed_date = Date.current - 2
      record = Ingestion::Record.account(external_id: external.external_id, name: external.name, currency: "USD",
        balance: BigDecimal("4250"), balance_date: observed_date, metadata: { balance_policy: { current_anchor: true, anchor_date: "balance_date" } })
      completed = mock("complete portfolio valuation")
      completed.stubs(:capabilities).returns([])
      completed.expects(:list_accounts).returns(account_page(external.external_id))
      completed.expects(:fetch_balance).with { |arguments| arguments[:cursor] == "remaining-portfolio-assets" }
        .returns(Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot",
          coverage: { "end" => observed_date.to_time(:utc).iso8601 }))
      Provider::AccountData::Syncer.new(connection, adapter: completed).perform_sync(connection.syncs.create!)
      assert_equal BigDecimal("4250"), account.reload.balance
      assert_equal observed_date, account.valuations.current_anchor.sole.entry.date
      assert_equal BigDecimal("4250"), external.reload.current_balance
      assert_nil cursor.reload.state["progress"]
      assert_equal observed_date, cursor.covered_through.to_date
    end
  end

  test "connection token replacement during a grouped read rejects the old response before capture or publication" do
    with_provider_encryption do
      connection, external, = linked_connection
      adapter = stub("stale connection adapter")
      adapter.stubs(:transaction_scope).returns(:connection)
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      partial = Provider::AccountData::Page.new(records: [ transaction_record("stale-connection-token") ], complete: false, mode: "delta")
      account_id = external.external_id
      adapter.define_singleton_method(:fetch_transaction_group) do |generation_id:, start_cursor:, cursor:|
        ProviderConnection.find(connection.id).update!(credentials: { "access_token" => "replacement-token" })
        Provider::AccountData::TransactionGroup.new(generation_id: generation_id, start_cursor: start_cursor, request_cursor: cursor,
          next_cursor: "stale-terminal", complete: true, account_pages: { account_id => partial }, unassigned_removed_ids: [], evidence: {})
      end
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) do
          Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
        end
      end
      assert_equal 0, connection.provider_sync_generations.sole.pages.count
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
      assert_nil connection.reload.lease_owner
      assert_equal 1, connection.credential_revision
    end
  end

  test "an asynchronous export captures progress and releases its lease without reporting failure" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      resume_at = 10.seconds.from_now.change(usec: 0)
      adapter = mock("preparing export")
      adapter.expects(:list_accounts).with(cursor: nil).returns(Provider::AccountData::Page.new(
        records: [], complete: false, progress_cursor: "private-poll-reference", coverage: { "available_at" => resume_at.iso8601 }))
      adapter.expects(:fetch_balance).never
      DebugLogEntry.expects(:capture).never

      error = assert_raises(Provider::AccountData::DeferredPage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
      end

      assert_equal resume_at, error.resume_at
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "accounts")
      assert_nil checkpoint.cursor
      assert_nil checkpoint.covered_through
      assert_equal "private-poll-reference", checkpoint.state.dig("progress", "cursor")
      assert connection.ingestion_batches.sole.applied?
      assert_nil connection.reload.lease_owner
      assert_empty connection.external_accounts
    end
  end

  test "a later attempt of the same sync advances saved export progress without replacing prior evidence" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      waiting = mock("waiting export")
      waiting.expects(:list_accounts).returns(Provider::AccountData::Page.new(records: [], complete: false,
        progress_cursor: "poll-1", coverage: { "available_at" => 10.seconds.from_now.iso8601 }))
      assert_raises(Provider::AccountData::DeferredPage) do
        Provider::AccountData::Syncer.new(connection, adapter: waiting).perform_sync(sync)
      end
      original = connection.ingestion_batches.sole
      original_payload = original.payload
      sync.update!(provider_attempt: 1)
      resumed = mock("ready export")
      resumed.expects(:list_accounts).with(cursor: "poll-1").returns(account_page("ready-account"))
      Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(sync)

      assert_equal 2, connection.ingestion_batches.count
      assert_equal original_payload, original.reload.payload
      assert_equal [ sync.id ], connection.ingestion_batches.distinct.pluck(:sync_id)
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "accounts")
      assert_nil checkpoint.state["progress"]
      assert_not_equal original.id, checkpoint.ingestion_batch_id
      assert_equal [ "ready-account" ], connection.external_accounts.pluck(:external_id)
    end
  end

  test "delayed account work resumes without refetching completed independent streams" do
    with_provider_encryption do
      connection, external, account = linked_connection
      sync = connection.syncs.create!
      waiting = transaction_adapter(external, records: [ transaction_record("before-delay") ])
      waiting.unstub(:fetch_balance)
      waiting.expects(:fetch_balance).returns(Provider::AccountData::Page.new(records: [], complete: false,
        progress_cursor: "balance-poll", coverage: { "available_at" => 10.seconds.from_now.iso8601 }))
      Account.any_instance.expects(:sync_later).never
      assert_raises(Provider::AccountData::DeferredPage) do
        Provider::AccountData::Syncer.new(connection, adapter: waiting).perform_sync(sync)
      end
      Account.any_instance.unstub(:sync_later)
      entry = account.entries.find_by!(source: "up", external_id: "before-delay")
      sync.update!(provider_attempt: 1)
      resumed = mock("ready balance")
      resumed.stubs(:capabilities).returns([ "transactions" ])
      resumed.expects(:list_accounts).never
      resumed.expects(:fetch_transactions).never
      resumed.expects(:fetch_balance).with { |args| args[:cursor] == "balance-poll" }.returns(account_page(external.external_id))
      Account.any_instance.expects(:sync_later).with(parent_sync: sync, window_start_date: nil, window_end_date: nil).once

      assert_no_difference "account.entries.count" do
        Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(sync)
      end
      assert_equal entry.id, account.entries.find_by!(source: "up", external_id: "before-delay").id
      assert_equal 1, connection.ingestion_batches.where(stream: "transactions").count
      assert_equal 2, connection.ingestion_batches.where(stream: "balances").count
    end
  end

  test "deferred export responses require a durable cursor and a bounded retry date before capture" do
    with_provider_encryption do
      [ { progress_cursor: nil, available_at: 1.minute.from_now.iso8601 },
        { progress_cursor: "poll", available_at: "invalid-date" },
        { progress_cursor: "poll", available_at: 2.days.from_now.iso8601 } ].each do |values|
        connection = create_provider_connection
        adapter = mock("invalid deferred response")
        adapter.expects(:list_accounts).returns(Provider::AccountData::Page.new(records: [], complete: false,
          progress_cursor: values[:progress_cursor], coverage: { "available_at" => values[:available_at] }))
        assert_raises(Provider::AccountData::InvalidResponse) do
          Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
        end
        assert_empty connection.ingestion_batches
        assert_empty connection.provider_sync_checkpoints
      end
    end
  end

  test "cancellation during the last upstream read cannot fan out a new account child" do
    with_provider_encryption do
      connection, external, = linked_connection
      sync = connection.syncs.create!(status: "syncing")
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      page = account_page(external.external_id)
      adapter.define_singleton_method(:fetch_balance) do |**_arguments|
        Sync.find(sync.id).request_cancel!
        page
      end
      Account.any_instance.expects(:sync_later).never

      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)

      assert sync.reload.cancel_requested_at?
      assert_empty sync.children
      assert connection.ingestion_batches.find_by!(stream: "balances").applied?
    end
  end

  test "ordinary account responses retain the link revision captured before the request" do
    with_provider_encryption do
      connection, external, account = linked_connection
      link = external.account_provider
      sync = connection.syncs.create!
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      record = Ingestion::Record.account(external_id: external.external_id, name: "Checking", currency: "USD", balance: BigDecimal("9999"))
      adapter.define_singleton_method(:fetch_balance) do |**_arguments|
        # Selected source identity is immutable. A concurrent link revision
        # still invalidates a response captured before that revision.
        link.touch
        Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot")
      end
      original = account.attributes.slice("balance", "cash_balance", "currency")
      Account.any_instance.expects(:sync_later).never

      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
      end

      assert_equal original, account.reload.attributes.slice("balance", "cash_balance", "currency")
      batch = connection.ingestion_batches.find_by!(stream: "balances")
      assert batch.captured?
      assert_equal external.id, batch.source_binding.fetch("external_account_id")
      assert_equal link.id, batch.source_binding.fetch("account_provider_id")
      assert_equal link.lock_version - 1, batch.source_binding.fetch("account_provider_revision")
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "balances")
    end
  end

  test "connection credentials replaced during an ordinary request cannot publish the captured response" do
    with_provider_encryption do
      connection, external, account = linked_connection
      original = account.attributes.slice("balance", "cash_balance", "currency")
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      record = Ingestion::Record.account(external_id: external.external_id, name: "Checking", currency: "USD", balance: BigDecimal("9999"))
      adapter.define_singleton_method(:fetch_balance) do |**_arguments|
        connection.update!(credentials: { "access_token" => "replacement-token" })
        Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot")
      end
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      batch = connection.ingestion_batches.find_by!(stream: "balances")
      capture = Ingestion::Codec.load(batch.payload).evidence.fetch("request_grant")
      assert_equal connection.reload.credential_revision - 1, capture["before"]["connection"]["credential_revision"]
      assert_equal capture["before"], capture["after"]
      assert batch.captured?
      assert_equal original, account.reload.attributes.slice("balance", "cash_balance", "currency")
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "balances")
      assert_provider_column_encrypted(batch, :payload, "request_grant")
    end
  end

  test "a newly captured account binding cannot legitimize an older adapter authorization" do
    with_provider_encryption do
      connection, external, = linked_connection
      authorization = connection.provider_authorizations.create!(credentials: { "session_id" => "original-session" })
      ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: external)
      adapter = stub
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      adapter.define_singleton_method(:capabilities) do
        authorization.update!(credentials: { "session_id" => "replacement-session" })
        []
      end
      adapter.expects(:fetch_balance).never
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      assert_empty connection.ingestion_batches.where(stream: "balances")
      assert_empty connection.provider_sync_checkpoints.where(stream: "balances")
    end
  end

  test "balance metadata updates the exact institution-scoped external account" do
    with_provider_encryption do
      connection = create_provider_connection
      unrelated = create_external_account(connection, external_id: "same-id", status: "ignored", current_balance: "55", name: "Other namespace")
      external = create_external_account(connection, external_id: "same-id", identity_namespace: "institution:one", current_balance: "10")
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
      before = unrelated.attributes
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).returns(Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot"))
      record = Ingestion::Record.account(external_id: "same-id", name: "Institution balance", currency: "USD", balance: BigDecimal("789"))
      adapter.expects(:fetch_balance).with do |arguments|
        arguments[:account][:metadata]["balance_snapshot_current"] == false
      end.returns(Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot"))
      assert_no_difference "ExternalAccount.count" do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      assert_equal before, unrelated.reload.attributes
      assert_equal BigDecimal("789"), external.reload.current_balance
      assert_equal "institution:one", external.identity_namespace
      assert_equal "Institution balance", external.name
      assert_equal BigDecimal("789"), account.reload.balance
    end
  end

  test "one invocation admits successive owned progress checkpoints and its final balance page" do
    with_provider_encryption do
      connection, external, account = linked_connection
      external.update!(current_balance: "5000", cash_balance: "5000")
      sync = connection.syncs.create!
      finish = 2.days.ago.utc.iso8601
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      final_record = Ingestion::Record.account(external_id: external.external_id, name: "Completed portfolio", currency: "USD", balance: BigDecimal("4250"))
      pages = [
        Provider::AccountData::Page.new(records: [], complete: false, next_cursor: "page-two", progress_cursor: "page-two", coverage: { "end" => finish }),
        Provider::AccountData::Page.new(records: [], complete: false, next_cursor: "page-three", progress_cursor: "page-three"),
        Provider::AccountData::Page.new(records: [ final_record ], complete: true, checkpoint_cursor: "valuation-complete", coverage: { "end" => finish })
      ]
      requests = []
      adapter.define_singleton_method(:fetch_balance) do |account:, cursor:, window:|
        requests << { cursor: cursor, window: window, balance: account[:balance] }
        pages.fetch(requests.size - 1)
      end

      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)

      assert_equal [ nil, "page-two", "page-three" ], requests.map { |request| request[:cursor] }
      assert_equal [ finish, finish ], requests.drop(1).map { |request| request[:window]["end"] }
      assert_equal [ BigDecimal("5000") ] * 3, requests.map { |request| request[:balance] }
      assert_equal BigDecimal("4250"), external.reload.current_balance
      assert_equal BigDecimal("4250"), account.reload.balance
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "balances")
      assert_equal "valuation-complete", checkpoint.cursor
      assert_nil checkpoint.state["progress"]
      assert_equal Time.iso8601(finish), checkpoint.covered_through
      batches = connection.ingestion_batches.where(stream: "balances").order(:sequence).to_a
      assert_equal [ 0, 1, 2 ], batches.map(&:sequence)
      assert batches.all?(&:applied?)
      assert_equal 3, batches.map { |batch| Ingestion::Codec.load(batch.payload).evidence.fetch("request_inputs").fetch("checkpoint") }.uniq.size
    end
  end

  test "request-local API routing changed during balance HTTP cannot overwrite cache or money" do
    with_provider_encryption do
      connection, external, account = linked_connection
      external.update!(sensitive_details: { "api_account_id" => "old-private-uid" })
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      response = Ingestion::Record.account(external_id: external.external_id, name: "Old routed result", currency: "USD", balance: BigDecimal("9999"))
      old_routing = nil
      adapter.define_singleton_method(:fetch_balance) do |account:, **_arguments|
        old_routing = account[:sensitive_details]["api_account_id"]
        ExternalAccount.find(external.id).update!(sensitive_details: { "api_account_id" => "corrected-private-uid" })
        Provider::AccountData::Page.new(records: [ response ], complete: true)
      end
      before = account.attributes.slice("balance", "cash_balance", "currency")
      Account.any_instance.expects(:sync_later).never

      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      assert_equal "old-private-uid", old_routing
      assert_equal "corrected-private-uid", external.reload.sensitive_details["api_account_id"]
      assert_equal "Checking", external.name
      assert_equal before, account.reload.attributes.slice("balance", "cash_balance", "currency")
      batch = connection.ingestion_batches.find_by!(stream: "balances")
      assert batch.captured?
      proof = Ingestion::Codec.load(batch.payload).evidence.fetch("request_inputs")
      refute_includes JSON.generate(proof), "old-private-uid"
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "balances")
    end
  end

  test "a stale source date window is rejected before the adapter reads an account" do
    with_provider_encryption do
      connection, external, = linked_connection
      adapter = stub
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      adapter.define_singleton_method(:capabilities) do
        ExternalAccount.find(external.id).update!(sync_start_date: Date.current - 180)
        []
      end
      adapter.expects(:fetch_balance).never
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      assert_empty connection.ingestion_batches.where(stream: "balances")
    end
  end

  test "selected Sync window changed during HTTP retains the page and rejects publication" do
    with_provider_encryption do
      connection, external, account = linked_connection
      sync = connection.syncs.create!
      adapter = stub(capabilities: [])
      adapter.expects(:list_accounts).returns(account_page(external.external_id))
      response = account_page(external.external_id)
      adapter.define_singleton_method(:fetch_balance) do |**_arguments|
        Sync.find(sync.id).update!(window_start_date: Date.current - 180)
        response
      end
      original = account.attributes.slice("balance", "cash_balance", "currency")
      Account.any_instance.expects(:sync_later).never
      assert_raises(Provider::AccountData::StaleWriter) { Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync) }
      assert_equal original, account.reload.attributes.slice("balance", "cash_balance", "currency")
      assert connection.ingestion_batches.find_by!(stream: "balances").captured?
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "balances")
    end
  end

  private
    def account_page(external_id, complete: true, next_cursor: nil, checkpoint_cursor: nil)
      record = Ingestion::Record.account(external_id: external_id, name: "Checking", currency: "USD")
      Provider::AccountData::Page.new(
        records: [ record ], complete: complete, mode: "snapshot",
        next_cursor: next_cursor, checkpoint_cursor: checkpoint_cursor
      )
    end

    def transaction_record(external_id, date: Date.current)
      Ingestion::Record.transaction(
        external_id: external_id, name: "Imported purchase", currency: "USD", date: date,
        amount: BigDecimal("91.37"), pending: false
      )
    end

    def linked_connection
      connection = create_provider_connection
      external = create_external_account(connection, external_id: "linked-account")
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      %w[transactions balances].each do |resource|
        Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource)
      end
      [ connection, external, account ]
    end

    def transaction_adapter(external_account, records:)
      adapter = mock("transaction adapter")
      adapter.stubs(:capabilities).returns([ "transactions" ])
      adapter.stubs(:fetch_balance).returns(account_page(external_account.external_id))
      adapter.expects(:list_accounts).with(cursor: nil).returns(account_page(external_account.external_id))
      adapter.expects(:fetch_transactions).with { |arguments|
        arguments.fetch(:account)[:external_id] == external_account.external_id && arguments[:cursor].nil? &&
          arguments.fetch(:window).key?("start") && arguments.fetch(:window).key?("end")
      }.returns(Provider::AccountData::Page.new(records: records, complete: true, checkpoint_cursor: "transactions-complete"))
      adapter
    end
end
