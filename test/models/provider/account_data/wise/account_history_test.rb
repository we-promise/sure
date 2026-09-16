require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Wise::AccountHistoryTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  History = Provider::AccountData::Wise::AccountHistory

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "checked archives supply factory overlap policy and retained provenance without changing financial rows" do
    with_wise_copy(rows: [ transfer("2026-01-03T00:30:00+14:00"), statement, activity ]) do |context|
      before = identity_financial_snapshot(context)
      snapshot = collect(context)
      history = snapshot.fetch("accounts").fetch("balance-1")

      assert_equal({ "legacy_transfer_cutoff" => "2026-01-03", "has_legacy_history" => true, "has_statement_history" => true }, history.fetch("policy"))
      assert_equal context.mapping.id, history.dig("provenance", "account", "mapping_id")
      assert_equal context.mapping.source_checksum, history.dig("provenance", "account", "source_checksum")
      assert_equal context.control.high_water_mark.fetch("copy_run_id"), history.dig("provenance", "item", "copy_run_id")
      assert snapshot.frozen?
      assert_raises(FrozenError) { history.fetch("policy")["has_statement_history"] = false }

      client = mock("Wise overlap transport")
      adapter = build_adapter(context, snapshot, client)
      account = adapter.normalize_account(id: "balance-1", type: "STANDARD", amount: { value: "100", currency: "EUR" })
      client.expects(:get_balance_statement_page).returns(items: [ statement, statement.merge("referenceNumber" => "incoming", "amount" => { "value" => "30", "currency" => "EUR" }) ], next_cursor: nil)
      page = adapter.fetch_transactions(account: account, window: window)
      assert_equal [ "wise_statement_incoming" ], page.records.map { |row| row[:external_id] }
      assert_equal history.fetch("provenance"), page.evidence.dig("retained_history", "provenance")
      refute account[:metadata].key?(:transaction_policy)
      refute_includes account[:metadata].inspect, context.mapping.source_checksum
      client.expects(:get_transfers_page).never
      client.expects(:get_activities_page).returns(items: [], next_cursor: nil)
      assert adapter.fetch_transactions(account: account, window: window, cursor: page.next_cursor).complete?
      assert_equal before, identity_financial_snapshot(context)
      assert_empty context.control.provider_connection.provider_sync_checkpoints.where(stream: "transactions")
    end
  end

  test "legacy-only history continues through transfer and activity pages without authorizing failed statements" do
    with_wise_copy(rows: [ activity, transfer("2026-01-08"), transfer("2026-01-03T00:00:00Z") ]) do |context|
      snapshot = collect(context)
      assert_equal({ "legacy_transfer_cutoff" => "2026-01-03", "has_legacy_history" => true, "has_statement_history" => false }, snapshot.dig("accounts", "balance-1", "policy"))
      client = mock("Wise legacy overlap transport")
      adapter = build_adapter(context, snapshot, client)
      account = Ingestion::Record.account(external_id: "balance-1", name: "EUR", currency: "EUR", account_type: "STANDARD",
        metadata: { transaction_policy: { statement_fallback_authorized: true } })
      client.expects(:get_balance_statement_page).returns(items: [], next_cursor: nil)
      first = adapter.fetch_transactions(account: account, window: window)
      client.expects(:get_transfers_page).with(context.item.profile_id, cursor: nil).returns(items: [], next_cursor: nil)
      second = adapter.fetch_transactions(account: account, window: window, cursor: first.next_cursor)
      refute second.complete?
      client.expects(:get_balance_statement_page).raises(Provider::Wise::WiseError.new("Denied", :access_forbidden))
      assert_raises(Provider::Wise::WiseError) { adapter.fetch_transactions(account: account, window: window) }
    end
  end

  test "empty caches and JAR activities establish no transfer or statement history including unlinked accounts" do
    [ nil, [], [ activity ] ].each do |rows|
      with_wise_copy(rows: rows, linked: false, type: "SAVINGS") do |context|
        history = collect(context).dig("accounts", "balance-1")
        assert_equal "SAVINGS", history.fetch("balance_type")
        assert_equal({ "legacy_transfer_cutoff" => nil, "has_legacy_history" => false, "has_statement_history" => false }, history.fetch("policy"))
        assert_nil context.external.current_account
        assert_equal context.mapping.id, history.dig("provenance", "account", "mapping_id")
      end
    end
  end

  test "malformed caches and ambiguous legacy dates require disposition instead of inventing a cutoff" do
    [ {}, [ nil ], [ transfer(nil) ], [ transfer("03/04/2026") ], [ transfer("2026-02-30T00:00:00Z") ] ].each do |rows|
      with_wise_copy(rows: rows) do |context|
        assert_raises(Provider::AccountData::InvalidResponse) { collect(context) }
      end
    end
  end

  test "archive binding rejects current financial currency drift without rejecting economic edits" do
    with_wise_copy(rows: [ transfer("2026-01-03") ]) do |context|
      original = collect(context)
      context.account.update!(balance: 999, name: "User description")
      assert_equal original, collect(context)
      context.account.update!(currency: "USD")
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { collect(context) }
    end
  end

  test "changed profile or missing archive cannot become a new-source empty policy" do
    with_wise_copy(rows: [ transfer("2026-01-03") ]) do |context|
      connection = context.control.provider_connection
      connection.update!(settings: connection.settings.merge("profile_id" => "another-profile"))
      assert_raises(Provider::AccountData::StaleWriter) { collect(context) }
      connection.update!(settings: connection.settings.merge("profile_id" => context.item.profile_id))
      archives = connection.ingestion_batches.where(stream: "legacy_snapshot", scope_key: "WiseAccount:#{context.source.id}")
      ProviderMigrationAccountBinding.where(first_batch_id: archives.select(:id)).delete_all
      archives.delete_all
      assert_raises(Provider::AccountData::StaleWriter) { collect(context) }
    end
  end

  test "live descriptors detect archive selection changes without decrypting retained payloads" do
    with_wise_copy(rows: [ transfer("2026-01-03") ]) do |context|
      connection = context.control.provider_connection
      Provider::AccountData::MigrationCopier.any_instance.expects(:snapshot_for).never
      original = History.live_input(connection: connection)
      assert_equal context.mapping.source_checksum, original.dig("accounts", context.external.id, "source", "source_checksum")
      context.mapping.update!(source_checksum: "v1-#{'f' * 64}")
      refute_equal original, History.live_input(connection: connection)
    end
  end

  test "genuinely new accounts ignore unproved settings and do not change the retained live descriptor" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "wise", credentials: { token: "private-token" },
        settings: { profile_id: "new-profile", account_policies: { "new-balance" => { statement_fallback_authorized: true } } })
      begin
        original = History.live_input(connection: connection)
        create_external_account(connection, external_id: "new-balance", currency: "EUR")
        assert_equal original, History.live_input(connection: connection)
        snapshot = History.build(connection: connection, observed_at: Time.current)
        assert_empty snapshot.fetch("accounts")
        client = mock("Wise new profile transport")
        Provider::Wise.expects(:new).returns(client)
        adapter = Provider::AccountData::Wise.build(credentials: connection.credentials, settings: connection.settings,
          context: { timezone: "UTC", wise_account_history: snapshot })
        client.expects(:get_balance_statement_page).raises(Provider::Wise::WiseError.new("Denied", :access_forbidden))
        record = Ingestion::Record.account(external_id: "new-balance", name: "EUR", currency: "EUR", account_type: "STANDARD")
        assert_raises(Provider::Wise::WiseError) { adapter.fetch_transactions(account: record, window: window) }
      ensure
        connection&.destroy!
      end
    end
  end

  test "a bounded account archive cannot smuggle an unbounded number of policy rows" do
    rows = Array.new(History::MAX_TRANSACTION_ROWS + 1) { { "created" => "2026-01-01" } }
    with_wise_copy(rows: rows) do |context|
      assert_raises(Provider::AccountData::IncompletePage) { collect(context) }
    end
  end

  test "Registry and RequestGrant consume retained policy and reject evidence or link drift before requests and publication" do
    %i[archive link].each do |drift|
      with_wise_copy(rows: [ transfer("2026-01-03"), statement ]) do |context|
        # Fixture admission only: this is not a production activation command.
        context.control.update!(state: "active")
        connection = context.control.provider_connection
        connection.update!(status: "good")
        Provider::AccountData::Registry.stubs(:fetch).with("wise").returns(Provider::AccountData::Wise)
        client = mock("Wise admitted transport")
        Provider::Wise.expects(:new).returns(client)
        adapter = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
        record = adapter.normalize_account(id: "balance-1", type: "STANDARD", amount: { value: "100", currency: "EUR" })
        client.expects(:get_balance_statement_page).returns(items: [ statement ], next_cursor: nil)
        page, capture = adapter.request_grant.capture_request do
          assert_equal 0, ProviderConnection.connection.open_transactions
          adapter.fetch_transactions(account: record, window: window)
        end
        assert_empty page.records
        assert_equal "2026-01-03", page.evidence.dig("retained_history", "policy", "legacy_transfer_cutoff")
        assert capture.dig("before", "runtime_inputs", "frozen_context", "wise_account_history").present?
        assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)

        if drift == :archive
          context.mapping.update!(source_checksum: "v1-#{'f' * 64}")
        else
          context.link.update!(updated_at: 1.second.from_now)
        end
        assert_raises(Provider::AccountData::StaleWriter) do
          adapter.request_grant.capture_request { flunk "Changed retained input reached the provider" }
        end
        assert_raises(Provider::AccountData::StaleWriter) do
          Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)
        end
      end
    end
  end

  test "committed statement posting promotes only later factories and interrupted same-Sync replay keeps its transfer policy" do
    travel_to Time.utc(2026, 9, 15, 12) do
      with_wise_copy(rows: [ transfer("2026-01-03") ]) do |context|
        connection = admit_native_fixture(context)
        client = mock("Wise production construction")
        Provider::Wise.stubs(:new).returns(client)
        Account.any_instance.stubs(:sync_later)
        sync = connection.syncs.create!(window_end_date: Date.new(2026, 1, 20))
        expect_wise_inventory(client)
        client.expects(:get_balance_statement_page).returns(items: [ incoming_statement ], next_cursor: nil)
        client.expects(:get_transfers_page).raises(Provider::Wise::WiseError.new("Retry transport", :server_error))

        assert_raises(Provider::AccountData::Error) { Provider::AccountData::Syncer.new(connection).perform_sync(sync) }
        checkpoint = connection.provider_sync_checkpoints.find_by!(stream: Provider::AccountData::Wise::StatementHistory::STREAM)
        first = connection.ingestion_batches.where(stream: "transactions", status: "applied").sole
        assert_equal first.id, checkpoint.state.fetch("batch_id")
        assert_equal 1, context.account.entries.count
        assert_equal false, Ingestion::Codec.load(first.payload).evidence.dig("retained_history", "policy", "has_statement_history")
        assert_empty connection.provider_sync_checkpoints.where(stream: "transactions")

        travel 1.minute
        # Factory clock remains sync.created_at. All original completed pages
        # replay without HTTP, and the unfinished chain still requests transfers.
        client.expects(:get_transfers_page).returns(items: [], next_cursor: nil)
        client.expects(:get_activities_page).returns(items: [], next_cursor: nil)
        assert_no_difference "Entry.count" do
          Provider::AccountData::Syncer.new(connection).perform_sync(sync.reload)
        end
        assert_equal checkpoint.id, connection.provider_sync_checkpoints.find_by!(stream: Provider::AccountData::Wise::StatementHistory::STREAM).id

        travel 1.minute
        next_sync = connection.syncs.create!(window_end_date: Date.new(2026, 1, 20))
        expect_wise_inventory(client)
        client.expects(:get_balance_statement_page).returns(items: [ incoming_statement ], next_cursor: nil)
        client.expects(:get_activities_page).returns(items: [], next_cursor: nil)
        Provider::AccountData::Syncer.new(connection).perform_sync(next_sync)
        next_page = Ingestion::Codec.load(connection.ingestion_batches.where(sync: next_sync, stream: "transactions",
          scope_key: "account:#{context.external.id}").order(:sequence).first.payload)
        assert_equal true, next_page.evidence.dig("retained_history", "policy", "has_statement_history")
        assert_equal checkpoint.id, next_page.evidence.dig("retained_history", "provenance", "statement_history", "checkpoint_id")
        assert_equal first.id, checkpoint.reload.state.fetch("batch_id")
        assert_equal 1, context.account.entries.count
      end
    end
  end

  test "publication failure leaves no promotion and the captured statement can replay with its original policy" do
    travel_to Time.utc(2026, 9, 15, 12) do
      with_wise_copy(rows: [ transfer("2026-01-03") ]) do |context|
        connection = admit_native_fixture(context)
        client = mock("Wise captured statement")
        Provider::Wise.stubs(:new).returns(client)
        Account.any_instance.stubs(:sync_later)
        sync = connection.syncs.create!(window_end_date: Date.new(2026, 1, 20))
        expect_wise_inventory(client)
        client.expects(:get_balance_statement_page).returns(items: [ incoming_statement ], next_cursor: nil)
        Account::ProviderImportAdapter.any_instance.expects(:import_transaction).raises(Provider::AccountData::Error, "Publication interrupted")
        assert_raises(Provider::AccountData::Error) { Provider::AccountData::Syncer.new(connection).perform_sync(sync) }
        captured = connection.ingestion_batches.where(stream: "transactions", scope_key: "account:#{context.external.id}").sole
        original = captured.payload
        assert captured.captured?
        assert_empty connection.provider_sync_checkpoints.where(stream: Provider::AccountData::Wise::StatementHistory::STREAM)
        assert_empty context.account.entries

        Account::ProviderImportAdapter.any_instance.unstub(:import_transaction)
        travel 1.minute
        client.expects(:get_transfers_page).returns(items: [], next_cursor: nil)
        client.expects(:get_activities_page).returns(items: [], next_cursor: nil)
        Provider::AccountData::Syncer.new(connection).perform_sync(sync.reload)
        assert captured.reload.applied?
        assert_equal original, captured.payload
        assert_equal captured.id, connection.provider_sync_checkpoints.find_by!(stream: Provider::AccountData::Wise::StatementHistory::STREAM).state.fetch("batch_id")
        assert_equal 1, context.account.entries.count
      end
    end
  end

  test "native unlink drops only retained financial policy and invalidates the captured request" do
    with_wise_copy(rows: [ transfer("2026-01-03") ]) do |context|
      connection = admit_native_fixture(context)
      client = mock("Wise detached source")
      Provider::Wise.stubs(:new).returns(client)
      original = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
      record = original.normalize_account(id: "balance-1", type: "STANDARD", amount: { value: "100", currency: "EUR" })
      client.expects(:get_balance_statement_page).twice.returns(items: [], next_cursor: nil)
      _page, proof = original.request_grant.capture_request { original.fetch_transactions(account: record, window: window) }
      archives = connection.ingestion_batches.order(:id).map(&:attributes)
      financial = context.account.reload.attributes.slice("balance", "cash_balance", "currency", "accountable_type", "accountable_id")

      assert Account::Unlink.new(account: context.account, user: users(:family_admin)).call

      assert_raises(Provider::AccountData::StaleWriter) { original.request_grant.capture_request { flunk "Detached input reached HTTP" } }
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: proof, require_runtime_inputs: true)
      end
      fresh = Provider::AccountData::Registry.build(connection.reload, observed_at: Time.current)
      page, = fresh.request_grant.capture_request { fresh.fetch_transactions(account: record, window: window) }
      client.expects(:get_transfers_page).never
      client.expects(:get_activities_page).returns(items: [], next_cursor: nil)
      last, = fresh.request_grant.capture_request { fresh.fetch_transactions(account: record, window: window, cursor: page.next_cursor) }
      assert last.complete?
      assert_empty collect(context).fetch("accounts")
      assert_nil page.evidence["retained_history"]
      assert_equal archives, connection.ingestion_batches.order(:id).map(&:attributes)
      assert_equal financial, context.account.reload.attributes.slice(*financial.keys)
      assert WiseAccount.exists?(context.source.id)

      AccountProvider.create!(account: context.account, provider: context.source, external_account: context.external.reload)
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { collect(context) }
    end
  end

  test "unlinked original source validation still rejects malformed retained history" do
    with_wise_copy(rows: {}) do |context|
      admit_native_fixture(context)
      assert Account::Unlink.new(account: context.account, user: users(:family_admin)).call
      assert_raises(Provider::AccountData::InvalidResponse) { collect(context) }
    end
  end

  private
    def admit_native_fixture(context)
      # Test admission only. No migration activation command is invoked.
      context.control.update!(state: "active")
      connection = context.control.provider_connection
      connection.update!(status: "good", sync_start_date: Date.new(2026, 1, 1))
      %w[transactions balances].each do |resource|
        Account::SourcePolicy.select!(account: context.account, account_provider: context.link.reload, resource: resource)
      end
      Provider::AccountData::Registry.stubs(:fetch).with("wise").returns(Provider::AccountData::Wise)
      connection
    end

    def expect_wise_inventory(client)
      client.expects(:get_balances_page).with(anything, type: "STANDARD")
        .returns(items: [ { id: "balance-1", type: "STANDARD", amount: { value: "100", currency: "EUR" } } ], next_cursor: nil)
      client.expects(:get_balances_page).with(anything, type: "SAVINGS").returns(items: [], next_cursor: nil)
      client.expects(:get_borderless_accounts_page).returns(items: [], next_cursor: nil)
    end

    def incoming_statement
      statement.merge("amount" => { "value" => "20", "currency" => "EUR" })
    end

    def with_wise_copy(rows:, linked: true, type: "STANDARD")
      with_provider_encryption do
        family = families(:dylan_family)
        item = WiseItem.create!(family: family, name: "Retained Wise policy", token: "private-token",
          profile_id: SecureRandom.uuid, profile_type: "personal")
        account = family.accounts.create!(name: "Wise history", currency: "EUR", balance: 100, accountable: Depository.new)
        begin
          source = item.wise_accounts.create!(balance_id: "balance-1", currency: "EUR", name: "EUR", current_balance: 100,
            raw_payload: { "id" => "balance-1", "type" => type }, raw_transactions_payload: rows)
          link = AccountProvider.create!(account: account, provider: source) if linked
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "wise", legacy_item_id: item.id, batch_size: 1)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(external_account: external, role: "external_account")
          yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link&.reload, copier: copier, control: control, mapping: mapping, external: external)
        ensure
          cleanup_identity_source(item, account)
        end
      end
    end

    def collect(context)
      History.build(connection: context.control.provider_connection.reload, observed_at: Time.current)
    end

    def build_adapter(context, snapshot, client)
      Provider::Wise.expects(:new).returns(client)
      connection = context.control.provider_connection
      Provider::AccountData::Wise.build(credentials: connection.credentials, settings: connection.settings,
        context: { timezone: "UTC", wise_account_history: snapshot })
    end

    def transfer(date)
      { "id" => "legacy-transfer", "created" => date }
    end

    def statement
      { "wise_statement" => true, "referenceNumber" => "statement-1", "date" => "2026-01-10T00:00:00Z",
        "amount" => { "value" => "-20", "currency" => "EUR" } }
    end

    def activity
      { "type" => "INTERBALANCE", "id" => "activity-1", "createdOn" => "2020-01-01T00:00:00Z" }
    end

    def window
      { start: "2026-01-01T00:00:00Z", end: "2026-01-20T00:00:00Z" }
    end
end
