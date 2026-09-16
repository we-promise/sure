require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Monobank::RetainedHistoryTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Collector = Provider::AccountData::Monobank::RetainedHistory
  Value = Provider::AccountData::MigrationValue

  class Client
    attr_reader :requests

    def initialize
      @requests = []
    end

    def get_statement_page(account_id:, from:, to:, before_request:)
      before_request.call
      requests << { account_id: account_id, from: from, to: to }
      { items: [], evidence: [] }
    end
  end

  setup do
    travel_to Time.utc(2026, 9, 15, 12)
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Registry.stubs(:fetch).with("monobank").returns(Provider::AccountData::Monobank)
    { include_pending: true, max_statement_requests_per_sync: 4, pending_lookback_days: 3, initial_history_days: 31 }.each do |key, value|
      Rails.configuration.x.monobank.stubs(:[]).with(key).returns(value)
    end
    @family_id = families(:dylan_family).id
    @family_timestamps = Family.find(@family_id).attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
  end

  teardown do
    Family.where(id: @family_id).update_all(@family_timestamps)
    travel_back
  end

  test "accepted archive supplies original statement boundaries and oldest Boolean-cast hold without financial or checkpoint writes" do
    with_source do |context|
      before = context.account.reload.attributes
      checkpoints = context.external.provider_connection.provider_sync_checkpoints.order(:id).map(&:attributes)
      snapshot = capture(context)
      row = snapshot.fetch("accounts").fetch(context.external.id)

      assert_equal (Time.current - 1.day).iso8601(9), row.dig("state", "statement_synced_through")
      assert_equal (Time.current - 31.days).iso8601(9), row.dig("state", "history_synced_from")
      assert_equal (Time.current - 15.days).iso8601(9), row.dig("state", "oldest_pending_at")
      assert_equal context.mapping.source_checksum, row.dig("context", "source", "source_checksum")
      assert_equal context.control.high_water_mark.fetch("copy_run_id"), row.dig("context", "source", "copy_run_id")
      assert_equal context.source.id, row.dig("context", "source", "legacy_id")
      assert_equal context.link.id, row.dig("context", "account_binding", "link", "id")
      assert_equal before, context.account.reload.attributes
      assert_equal checkpoints, context.external.provider_connection.provider_sync_checkpoints.order(:id).map(&:attributes)
      assert_empty context.account.entries
      assert snapshot.frozen?
      assert row.fetch("state").frozen?
      assert context.external.provider_connection.disabled?
      refute Provider::AccountData::Monobank.native_ready?
    end
  end

  test "factory uses the old hold only when pending is included and keeps its physical request budget" do
    with_source do |context|
      [ true, false ].each do |include_pending|
        client = Client.new
        Provider::Monobank.stubs(:new).with("private-retained-monobank-token").returns(client)
        configuration = Rails.configuration.x.monobank
        configuration.stubs(:[]).with(:include_pending).returns(include_pending)
        configuration.stubs(:[]).with(:max_statement_requests_per_sync).returns(1)
        configuration.stubs(:[]).with(:pending_lookback_days).returns(3)
        configuration.stubs(:[]).with(:initial_history_days).returns(31)
        adapter = Provider::AccountData::Registry.build(context.external.provider_connection, observed_at: Time.current)
        expected = include_pending ? 15.days.ago : 3.days.ago
        page, = adapter.request_grant.capture_request { adapter.fetch_transactions(account: record(context)) }

        assert_equal [ { account_id: context.external.external_id, from: expected, to: Time.current } ], client.requests
        assert page.complete?
        assert_equal !include_pending, page.coverage.key?("pending_scope")
        assert_raises(Provider::AccountData::BudgetExhausted) do
          adapter.fetch_transactions(account: record(context), cursor: page.checkpoint_cursor)
        end
      end
    end
  end

  test "native progress and completed cursors resume without reinterpreting the retained seed or rereading archive payloads" do
    with_source(history_days: 20) do |context|
      connection = context.external.provider_connection
      client = Client.new
      Provider::Monobank.stubs(:new).returns(client)
      adapter = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
      page, proof = adapter.request_grant.capture_request { adapter.fetch_transactions(account: record(context)) }
      assert_not page.complete?
      assert page.progress_cursor
      assert_equal 15.days.ago, client.requests.sole.fetch(:from)
      wrong = Ingestion::Record.account(**record(context).attributes.merge(metadata: {
        runtime_external_account_id: context.external.id, runtime_identity_namespace: "another"
      }))
      assert_raises(Provider::AccountData::StaleWriter) { adapter.fetch_transactions(account: wrong, cursor: page.progress_cursor) }
      sync = connection.syncs.create!
      batch = create_provider_batch(connection, sync: sync, external_account: context.external, stream: "transactions",
        scope_key: "account:#{context.external.id}", mode: "snapshot", complete: false,
        status: "applied", applied_at: Time.current, payload: Ingestion::Codec.dump(page))
      native = connection.provider_sync_checkpoints.create!(stream: "transactions", scope_key: "account:#{context.external.id}",
        external_account: context.external, state: { "progress" => { "cursor" => page.progress_cursor, "ingestion_batch_id" => batch.id } })
      Provider::AccountData::RetainedRow.any_instance.expects(:account).never

      assert adapter.request_grant.verify!
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: proof, require_runtime_inputs: true)
      finished, = adapter.request_grant.capture_request do
        adapter.fetch_transactions(account: record(context), cursor: native.state.fetch("progress").fetch("cursor"))
      end
      assert finished.complete?
      assert_equal({ account_id: context.external.external_id, from: 31.days.ago, to: 20.days.ago }, client.requests.last)
      assert_nil native.reload.covered_through
      assert_equal page.progress_cursor, native.state.dig("progress", "cursor")
      before = native.attributes
      copied = legacy_checkpoint(context)
      columns = Value.decode(copied.state.fetch("columns"))
      copied.update!(state: copied.state.merge("columns" => Value.encode(columns.merge("statement_synced_through" => Time.current))))
      assert_raises(Provider::AccountData::StaleWriter) { adapter.request_grant.capture_request { flunk "Changed retained coverage reached HTTP" } }
      assert_equal before, native.reload.attributes
    end
  end

  test "missing archive or mapping cannot silently become a new account with empty history" do
    with_source do |context|
      archive = context.external.provider_connection.ingestion_batches.find_by!(stream: "legacy_snapshot", external_account: context.external, sequence: 0)
      ProviderMigrationAccountBinding.where(first_batch_id: archive.id).delete_all
      archive.delete
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
      context.mapping.delete
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
    end
  end

  test "another stream any-columns lookalike and ambiguous legacy state never supply history" do
    with_source do |context|
      copied = legacy_checkpoint(context)
      connection = context.external.provider_connection
      ApplicationRecord.transaction do
        copied.update!(stream: "transactions")
        assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
        raise ActiveRecord::Rollback
      end
      ProviderSyncCheckpoint.create!(provider_connection: connection, external_account: context.external, stream: "legacy_state",
        scope_key: "unrelated:#{SecureRandom.uuid}", state: copied.reload.state)
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
    end
  end

  test "changed link foreign inventory and wrong namespace reject the captured source" do
    with_source do |context|
      another = accounts(:credit_card)
      ApplicationRecord.transaction do
        context.link.update!(account: another)
        assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
        raise ActiveRecord::Rollback
      end
      ApplicationRecord.transaction do
        context.external.update_columns(identity_namespace: "another-institution")
        assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
        raise ActiveRecord::Rollback
      end
      foreign = create_provider_connection(provider_key: "monobank", family: families(:empty), credentials: { "access_token" => "foreign" })
      begin
        external = create_external_account(foreign)
        context.external.provider_connection.with_lock do
          assert_raises(Provider::AccountData::StaleWriter) do
            Collector.build(connection: context.external.provider_connection, observed_at: Time.current, external_accounts: [ external ])
          end
        end
      ensure
        foreign.destroy!
      end
    end
  end

  test "legacy checkpoint shape dates and native-looking coverage must match the original account archive exactly" do
    with_source do |context|
      checkpoint = legacy_checkpoint(context)
      original = checkpoint.state
      columns = Value.decode(original.fetch("columns"))
      changes = [
        { cursor: "unrelated-native-cursor" }, { covered_through: Time.current }, { schema_version: 2 },
        { state: original.merge("columns" => Value.encode(columns.merge("statement_synced_through" => Time.current))) },
        { state: original.merge("columns" => Value.encode(columns.merge("last_synced_at" => Time.current))) }
      ]
      changes.each do |attributes|
        ApplicationRecord.transaction do
          checkpoint.reload.update!(attributes)
          assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
          raise ActiveRecord::Rollback
        end
      end
      assert_equal original, checkpoint.reload.state
      assert_nil checkpoint.covered_through
    end
  end

  test "a genuinely new source has an explicit empty seed and rejects request namespace substitution" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "monobank", credentials: { "access_token" => "new-token" })
      external = create_external_account(connection, external_id: "new-card", currency: "UAH")
      account = connection.family.accounts.create!(name: "New Monobank account", currency: "UAH", balance: 0, accountable: Depository.new)
      link = AccountProvider.create!(account: account, external_account: external)
      begin
        snapshot = connection.with_lock { Collector.build(connection: connection, observed_at: Time.current) }
        assert_nil snapshot.fetch("item")
        assert_equal({}, snapshot.dig("accounts", external.id, "state"))
        Provider::Monobank.stubs(:new).returns(mock("must not fetch foreign namespace"))
        adapter = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
        wrong = Ingestion::Record.account(external_id: external.external_id, name: external.name, currency: "UAH",
          metadata: { runtime_external_account_id: external.id, runtime_identity_namespace: "another" })
        assert_raises(Provider::AccountData::StaleWriter) { adapter.fetch_transactions(account: wrong) }
      ensure
        link.delete
        connection.destroy!
        account.destroy!
      end
    end
  end

  private
    def with_source(history_days: 31)
      with_provider_encryption do
        family = families(:dylan_family)
        item = MonobankItem.create!(family: family, name: "Retained Monobank", access_token: "private-retained-monobank-token")
        account = family.accounts.create!(name: "Retained card", currency: "UAH", balance: 12, accountable: Depository.new)
        begin
          source = item.monobank_accounts.create!(account_id: SecureRandom.uuid, name: "Card", currency: "UAH", account_kind: "card", account_type: "black",
            statement_synced_through: 1.day.ago, history_synced_from: history_days.days.ago, raw_transactions_payload: [
              { "id" => "settled-old", "time" => 30.days.ago.to_i, "hold" => false },
              { "id" => "false-string", "time" => 25.days.ago.to_i, "hold" => "0" },
              { "id" => "held-old", "time" => 15.days.ago.to_i.to_s, "hold" => "true" },
              { "id" => "held-recent", "time" => 1.day.ago.to_i, "hold" => true },
              { "id" => "undated", "hold" => true }
            ])
          link = AccountProvider.create!(account: account, provider: source)
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "monobank", legacy_item_id: item.id)
          control = nil
          10.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account, link: link.reload,
            copier: copier, control: control, mapping: mapping, external: external)
        ensure
          if control&.provider_connection
            connection = control.provider_connection
            connection.provider_sync_checkpoints.delete_all
            ProviderMigrationAccountBinding.where(family_id: control.family_id,
              provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all
            connection.ingestion_batches.delete_all
            connection.syncs.delete_all
          end
          cleanup_identity_source(item, account)
        end
      end
    end

    def capture(context)
      connection = context.external.provider_connection
      connection.with_lock { Collector.build(connection: connection, observed_at: Time.current) }
    end

    def legacy_checkpoint(context)
      context.external.provider_connection.provider_sync_checkpoints.find_by!(stream: "legacy_state", external_account: context.external)
    end

    def record(context)
      external = context.external
      Ingestion::Record.account(external_id: external.external_id, name: external.name, currency: external.currency,
        metadata: { runtime_external_account_id: external.id, runtime_identity_namespace: external.identity_namespace })
    end
end
