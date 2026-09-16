require "test_helper"
require_relative "../../../../support/binance_history_bootstrap_test_helper"

class Provider::AccountData::Binance::HistoryBootstrapTest < ActiveSupport::TestCase
  include BinanceHistoryBootstrapTestHelper
  self.use_transactional_tests = false

  Publisher = Provider::AccountData::Binance::HistoryBootstrap
  Plan = Provider::AccountData::Binance::HistoryBootstrapPlan
  Value = Provider::AccountData::MigrationValue
  TIMESTAMP = BinanceHistoryBootstrapTestHelper::HISTORY_TIMESTAMP

  setup do
    DebugLogEntry.stubs(:capture)
    travel_to Time.utc(2026, 9, 15)
  end

  teardown do
    travel_back
  end

  test "installation retains financial UUIDs and proofs in one encrypted immutable receipt without coverage or activation" do
    with_history_copy do |context|
      publish_identities(context)
      entry = context.account.entries.where(entryable_type: "Trade").first
      entry.update!(name: "User correction", amount: 987, user_modified: true, import_locked: true)
      entry.entryable.update!(qty: 12, price: 45)
      before = identity_financial_snapshot(context)
      original = [ context.control.reload.attributes, context.external.reload.attributes, context.link.reload.attributes ]
      Provider::Binance.expects(:new).never
      queries = []
      subscriber = ->(*arguments) { queries << arguments.last[:sql] }
      result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { install(context) }
      checkpoint = ProviderSyncCheckpoint.find(result.checkpoint_id)
      batch = IngestionBatch.find(result.batch_id)

      assert_no_financial_sql(queries)
      assert_equal before, identity_financial_snapshot(context)
      assert_equal original, [ context.control.reload.attributes, context.external.reload.attributes, context.link.reload.attributes ]
      assert_nil checkpoint.cursor
      assert_nil checkpoint.covered_through
      assert_nil batch.sync_id
      assert_equal({}, batch.coverage)
      refute batch.complete?
      refute batch.payload.fetch("upstream_history_complete")
      assert batch.payload.fetch("requires_cutover_reverification")
      assert_equal context.account.entries.pluck(:id).sort, batch.payload.fetch("proofs").map { |proof| proof.fetch("entry_id") }.sort
      assert_provider_column_encrypted(batch, :payload, "binance_spot_BTCUSDT_42")
      assert_provider_column_encrypted(checkpoint, :state, "receipt_digest")
      assert_raises(ActiveRecord::RecordInvalid) { batch.update!(payload: {}) }
      assert context.control.quiescing?
      assert context.control.provider_connection.disabled?
      assert_empty context.control.provider_connection.syncs
    end
  end

  test "identical installation returns the same checkpoint and receipt without writes" do
    with_history_copy do |context|
      publish_identities(context)
      first = install(context)
      checkpoint_before = ProviderSyncCheckpoint.find(first.checkpoint_id).attributes
      batch_before = IngestionBatch.find(first.batch_id).attributes

      second = install(context)

      assert second.replayed
      assert_equal [ first.checkpoint_id, first.batch_id ], [ second.checkpoint_id, second.batch_id ]
      assert_equal checkpoint_before, ProviderSyncCheckpoint.find(first.checkpoint_id).attributes
      assert_equal batch_before, IngestionBatch.find(first.batch_id).attributes
    end
  end

  test "an unverified identity sweep or missing P2P leg cannot install a seed" do
    with_history_copy do |context|
      assert_raises(Publisher::Conflict) { install(context) }
      assert_no_seed(context)
      Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      assert_raises(Publisher::Conflict) { install(context) }
      assert_no_seed(context)
      context.account.entries.find_by!(external_id: "binance_p2p_order-01_funding").destroy!
      assert_raises(Publisher::Conflict) { install(context) }
      assert_no_seed(context)
    end
  end

  test "verification after a new identity sweep preserves the original signed installation" do
    with_history_copy do |context|
      publish_identities(context)
      original = install(context)
      checkpoint = ProviderSyncCheckpoint.find(original.checkpoint_id)
      batch = IngestionBatch.find(original.batch_id)
      before = [ checkpoint.attributes, batch.attributes ]
      identity = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family)
      travel 1.minute
      identity.restart_verification!
      publish_identities(context)
      signed_identity = batch.payload.fetch("identity_checkpoint")
      current_identity = ProviderSyncCheckpoint.find(signed_identity.fetch("id"))
      assert_operator current_identity.lock_version, :>, signed_identity.fetch("lock_version")

      queries = []
      subscriber = ->(*arguments) { queries << arguments.last[:sql] }
      result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        Publisher.new(mapping: context.mapping, family: context.family).verify!(checkpoint_id: checkpoint.id,
          batch_id: batch.id, receipt_digest: checkpoint.state.fetch("receipt_digest"))
      end

      assert_equal original.checkpoint_id, result.checkpoint_id
      assert_equal original.batch_id, result.batch_id
      assert_equal before, [ checkpoint.reload.attributes, batch.reload.attributes ]
      assert_no_financial_sql(queries)
      current_identity.update_columns(lock_version: signed_identity.fetch("lock_version") - 1)
      assert_raises(Publisher::Conflict) do
        Publisher.new(mapping: context.mapping, family: context.family).verify!(checkpoint_id: checkpoint.id,
          batch_id: batch.id, receipt_digest: checkpoint.state.fetch("receipt_digest"))
      end
    end
  end

  test "verification never installs missing input or accepts a different retained receipt" do
    with_history_copy do |context|
      publish_identities(context)
      verifier = Publisher.new(mapping: context.mapping, family: context.family)
      assert_raises(Publisher::Conflict) do
        verifier.verify!(checkpoint_id: SecureRandom.uuid, batch_id: SecureRandom.uuid, receipt_digest: "0" * 64)
      end
      assert_no_seed(context)
      original = install(context)
      assert_raises(Publisher::Conflict) do
        verifier.verify!(checkpoint_id: original.checkpoint_id, batch_id: original.batch_id, receipt_digest: "0" * 64)
      end
    end
  end

  test "withdrawn financial proof and pending alias drift refuse installation" do
    with_history_copy do |context|
      publish_identities(context)
      record = SourceRecord.find_by!(external_account: context.external, external_id: "binance_p2p_order-01_funding")
      record.update!(withdrawn: true)
      assert_raises(Publisher::Conflict) { install(context) }
      assert_no_seed(context)
      record.update!(withdrawn: false)
      entry = context.account.entries.find_by!(external_id: record.external_id)
      entry.entryable.update!(extra: { "binance" => { "pending" => true } })
      assert_raises(Publisher::Conflict) { install(context) }
      assert_no_seed(context)
    end
  end

  test "a missing P2P posting proof cannot be reconstructed from its existing Entry" do
    with_history_copy do |context|
      publish_identities(context)
      record = SourceRecord.find_by!(external_account: context.external, external_id: "binance_p2p_order-01_funding")
      record.entry_sources.sole.delete

      assert_raises(Publisher::Conflict) { install(context) }

      assert context.account.entries.exists?(external_id: record.external_id)
      assert_no_seed(context)
    end
  end

  test "changed source identity or entryable UUID behind verification cannot satisfy history proof" do
    with_history_copy do |context|
      publish_identities(context)
      entry = context.account.entries.find_by!(external_id: "binance_spot_BTCUSDT_42")
      entry.update!(external_id: "binance_spot_BTCUSDT_43")
      assert_raises(Publisher::Conflict) { install(context) }
      entry.update!(external_id: "binance_spot_BTCUSDT_42")
      previous = entry.entryable_id
      replacement = Trade.create!(security: securities(:aapl), qty: 2, price: 10, currency: "USD")
      begin
        entry.update_columns(entryable_id: replacement.id)
        assert_raises(Publisher::Conflict) { install(context) }
        assert_no_seed(context)
      ensure
        entry.update_columns(entryable_id: previous)
        replacement.destroy!
      end
    end
  end

  test "stale retained context and another family refuse installation" do
    with_history_copy do |context|
      publish_identities(context)
      reviewed = Plan.new(mapping: context.mapping, family: context.family).call.document.fetch("context")
      assert_raises(Publisher::Conflict) { Publisher.new(mapping: context.mapping, family: families(:empty)).install }
      assert_raises(Publisher::Conflict) { install(context, expected_context: reviewed.merge("copy_run_id" => SecureRandom.uuid)) }
      context.source.update!(raw_transactions_payload: {})
      assert_raises(Publisher::Conflict) { install(context, expected_context: reviewed) }
      assert_no_seed(context)
    end
  end

  test "checkpoint failure rolls back receipt capture and leaves existing identity proof intact" do
    with_history_copy do |context|
      publish_identities(context)
      old = [ IngestionBatch.count, SourceRecord.count, EntrySource.count, ProviderSyncCheckpoint.count ]
      ProviderSyncCheckpoint.any_instance.expects(:save!).raises(IOError, "installation interrupted")

      assert_raises(IOError) { install(context) }

      assert_equal old, [ IngestionBatch.count, SourceRecord.count, EntrySource.count, ProviderSyncCheckpoint.count ]
      assert_no_seed(context)
    end
  end

  test "lost installation checkpoint cannot replace retained receipt or permit recopy and legacy return" do
    with_history_copy do |context|
      publish_identities(context)
      result = install(context)
      ProviderSyncCheckpoint.find(result.checkpoint_id).delete

      assert_raises(Publisher::Conflict) { install(context) }
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { context.copier.run_quiesced(restart: true) }
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { context.copier.resume_legacy! }
      assert IngestionBatch.exists?(result.batch_id)
      assert_equal 1, seed_batches(context).count
    end
  end

  test "native cursor even without coverage or a native sync prevents installation" do
    with_history_copy do |context|
      publish_identities(context)
      checkpoint = context.external.provider_connection.provider_sync_checkpoints.create!(external_account: context.external,
        stream: "activities", scope_key: "account:#{context.external.id}", cursor: "already-progressed")
      assert_raises(Publisher::Conflict) { install(context) }
      assert_equal "already-progressed", checkpoint.reload.cursor
      checkpoint.delete
      context.external.provider_connection.syncs.create!
      assert_raises(Publisher::Conflict) { install(context) }
      assert_no_seed(context)
    end
  end

  test "production factory and sync consume sold-out pairs and the inclusive P2P seed then resume their own cursor" do
    with_history_copy do |context|
      publish_identities(context)
      result = install(context)
      receipt_before = IngestionBatch.find(result.batch_id).attributes
      seed_before = ProviderSyncCheckpoint.find(result.checkpoint_id).attributes
      connection, client = prepare_native(context)
      # Updating legacy cache after transition must have no effect on requests.
      context.source.update_columns(raw_transactions_payload: {})
      client.stop_on_trade = true
      assert_raises(Provider::AccountData::IncompletePage) { run_native(connection) }
      assert_equal TIMESTAMP, client.p2p_requests.first.fetch(:start_time)
      assert_equal({ pair: "BTCUSDT", market: "spot", from_id: 43 }, client.trade_requests.first)
      cursor = connection.provider_sync_checkpoints.find_by!(stream: "activities").state.dig("progress", "cursor")
      assert cursor
      assert_nil connection.provider_sync_checkpoints.find_by!(stream: "activities").covered_through

      client.stop_on_trade = false
      client.p2p_requests.clear
      client.trade_requests.clear
      run_native(connection)

      assert_empty client.p2p_requests
      assert_equal({ pair: "BTCUSDT", market: "spot", from_id: 43 }, client.trade_requests.first)
      assert_equal seed_before, ProviderSyncCheckpoint.find(result.checkpoint_id).attributes
      assert_equal receipt_before, IngestionBatch.find(result.batch_id).attributes
    end
  end

  test "replacing or deleting installed input after factory construction is rejected before HTTP" do
    [ :replace, :delete ].each do |change|
      with_history_copy do |context|
        publish_identities(context)
        result = install(context)
        connection, client = prepare_native(context)
        native = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
        checkpoint = ProviderSyncCheckpoint.find(result.checkpoint_id)
        attributes = checkpoint.attributes.except("id", "created_at", "updated_at")
        checkpoint.delete
        ProviderSyncCheckpoint.create!(attributes) if change == :replace

        assert_raises(Provider::AccountData::StaleWriter) do
          native.request_grant.capture_request { native.list_accounts }
        end
        assert_empty client.portfolio_requests
      end
    end
  end

  test "seed removal during HTTP retains the response but rejects publication" do
    with_history_copy do |context|
      publish_identities(context)
      result = install(context)
      connection, client = prepare_native(context)
      client.during_portfolio = -> { ProviderSyncCheckpoint.find(result.checkpoint_id).delete }

      assert_raises(Provider::AccountData::StaleWriter) { run_native(connection) }

      batches = connection.ingestion_batches.where(origin_kind: "provider", stream: "accounts")
      assert_equal [ "captured" ], batches.pluck(:status)
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "accounts")
      assert_equal 1, client.portfolio_requests.size
    end
  end

  test "a new factory refuses changed copy-time account currency or link revision" do
    [ :currency, :revision ].each do |change|
      with_history_copy do |context|
        publish_identities(context)
        install(context)
        connection, client = prepare_native(context)
        if change == :currency
          context.account.update!(currency: "EUR")
        else
          context.link.touch
        end

        assert_raises(Provider::AccountData::StaleWriter) do
          Provider::AccountData::Registry.build(connection, observed_at: Time.current)
        end
        assert_empty client.portfolio_requests
      end
    end
  end

  test "native unlink retains the signed installation without seeding the detached financial history" do
    with_history_copy do |context|
      publish_identities(context)
      installed = install(context)
      connection, client = prepare_native(context)
      original = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
      _page, proof = original.request_grant.capture_request { original.list_accounts }
      receipts = [ ProviderSyncCheckpoint.find(installed.checkpoint_id).attributes, IngestionBatch.find(installed.batch_id).attributes ]
      financial = identity_financial_snapshot(context)
      financial["account"] = financial.fetch("account").slice("balance", "cash_balance", "currency", "accountable_type", "accountable_id")

      assert Account::Unlink.new(account: context.account, user: users(:family_admin)).call

      assert_raises(Provider::AccountData::StaleWriter) { original.request_grant.capture_request { flunk "Detached seed reached HTTP" } }
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: proof, require_runtime_inputs: true)
      end
      assert_empty Publisher.runtime_input(connection.reload).fetch("seed")
      fresh = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
      fresh.request_grant.capture_request { fresh.list_accounts }
      assert_equal 2, client.portfolio_requests.size
      assert_equal receipts, [ ProviderSyncCheckpoint.find(installed.checkpoint_id).attributes, IngestionBatch.find(installed.batch_id).attributes ]
      after = identity_financial_snapshot(context)
      after["account"] = after.fetch("account").slice(*financial.fetch("account").keys)
      assert_equal financial, after
      assert BinanceAccount.exists?(context.source.id)

      AccountProvider.create!(account: context.account, provider: context.source, external_account: context.external.reload)
      assert_raises(Provider::AccountData::StaleWriter) { Provider::AccountData::Registry.build(connection, observed_at: Time.current) }
    end
  end

  test "detached seed still requires its original signed receipt" do
    with_history_copy do |context|
      publish_identities(context)
      installed = install(context)
      connection, = prepare_native(context)
      assert Account::Unlink.new(account: context.account, user: users(:family_admin)).call
      batch = IngestionBatch.find(installed.batch_id)
      payload = batch.payload.deep_dup
      payload.fetch("plan")["candidate_cached_history"] = {}
      batch.update!(payload: payload)

      assert_raises(Provider::AccountData::StaleWriter) { Publisher.runtime_input(connection) }
    end
  end

  private
    class HistoryClient
      attr_accessor :stop_on_trade, :during_portfolio
      attr_reader :p2p_requests, :trade_requests, :portfolio_requests

      def initialize
        @p2p_requests, @trade_requests, @portfolio_requests = [], [], []
      end

      def get_portfolio_page(source, page:)
        portfolio_requests << [ source, page ]
        during_portfolio&.call
        { items: [], next_cursor: nil }
      end

      def get_p2p_page(**arguments)
        p2p_requests << arguments
        { items: [], next_cursor: nil }
      end

      def get_trades_page(pair, **arguments)
        trade_requests << arguments.merge(pair: pair)
        raise Provider::AccountData::IncompletePage, "Interrupted history" if stop_on_trade
        { items: [], next_cursor: nil }
      end
    end

    def publish_identities(context)
      publisher = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family)
      result = nil
      10.times do
        result = publisher.run
        break if result.verified?
      end
      assert result.verified?
    end

    def install(context, **options)
      Publisher.new(mapping: context.mapping, family: context.family).install(**options)
    end

    def seed_batches(context)
      context.external.provider_connection.ingestion_batches.where(stream: Publisher::STREAM)
    end

    def assert_no_seed(context)
      assert_empty seed_batches(context)
      assert_empty context.external.provider_connection.provider_sync_checkpoints.where(stream: Publisher::STREAM)
    end

    def prepare_native(context)
      # Test-only readiness/ownership transition, never an activation command.
      context.control.update!(state: "active", writer_epoch: 1)
      connection = context.external.provider_connection
      connection.update!(status: "good", writer_epoch: 1)
      client = HistoryClient.new
      Provider::AccountData::Registry.stubs(:fetch).with("binance").returns(Provider::AccountData::Binance)
      Provider::Binance.stubs(:new).returns(client)
      [ connection, client ]
    end

    def run_native(connection)
      Provider::AccountData::Syncer.new(connection).perform_sync(connection.syncs.create!)
    end
end
