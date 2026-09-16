require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"
require_relative "../../../../support/onchain_capture_test_helper"

class Provider::AccountData::OnchainWallet::YahooCaptureSyncTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include OnchainCaptureTestHelper
  self.use_transactional_tests = false

  setup do
    travel_to Time.utc(2026, 9, 15, 12)
    @family = families(:dylan_family)
    @family_values = @family.reload.attributes.slice("timezone", "latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
    @family.update_columns(timezone: "UTC")
    DebugLogEntry.stubs(:capture)
    credentials = { "provider" => "yahoo_finance" }
    Wallet::FxConfiguration.stubs(:credentials).returns(credentials)
    @configuration = wallet_configuration(price_enabled: true)
    @configuration["fx"] = { "version" => 1, "provider" => "yahoo_finance", "endpoint" => "https://fx.example.test",
      "user_agent" => "captured-agent/v1", "min_interval_seconds" => "0.5", "acquisition_policy" => Wallet::FxAcquisition.yahoo_policy,
      "credential_fingerprint" => Wallet::FxConfiguration.fingerprint(credentials) }
    Wallet::Configuration.stubs(:build).returns(@configuration)
    Provider::AccountData::Registry.stubs(:fetch).with("onchain_wallet").returns(Wallet)
    Wallet::Client.any_instance.stubs(:sleep)
    Wallet::YahooFxReader.any_instance.stubs(:sleep)
  end

  teardown do
    Provider::AccountData::RequestGrant.unstub(:verify_capture!)
    Family.where(id: @family.id).update_all(@family_values)
    travel_back
  end

  test "each captured but unapplied Yahoo step resumes through production Syncer without another physical request" do
    %w[cookie crumb chart].each do |interrupted|
      with_wallet do |connection, external, sync|
        expect_market_prefix
        expect_cookie(interrupt: interrupted == "cookie")
        expect_crumb(interrupt: interrupted == "crumb") unless interrupted == "cookie"
        expect_chart(interrupt: true) if interrupted == "chart"
        assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
        Provider::AccountData::RequestGrant.unstub(:verify_capture!)
        batch = connection.ingestion_batches.where(status: "captured").sole
        original = batch.payload
        evidence = Ingestion::Codec.load(original).evidence.fetch("onchain_capture")
        assert_equal interrupted, evidence.dig("fragment", "operation", "arguments", "step")
        assert_provider_column_encrypted(batch, :payload, "private-#{interrupted}") unless interrupted == "chart"
        original_ids = connection.ingestion_batches.pluck(:id)

        travel 30.seconds
        expect_crumb if interrupted == "cookie"
        expect_chart unless interrupted == "chart"
        assert_no_difference [ "Entry.count", "Holding.count", "Balance.count", "ExchangeRate.count" ] { run_wallet(connection.reload, Sync.find(sync.id)) }
        assert batch.reload.applied?
        assert_equal original, batch.payload
        assert_equal 8, connection.ingestion_batches.count
        assert_equal original_ids.sort, connection.ingestion_batches.where(id: original_ids).pluck(:id).sort
        fragments = archive(connection, sync).fetch("fragments").select { |fragment| fragment.dig("operation", "action") == "fx_yahoo" }
        assert_equal %w[cookie crumb chart], fragments.map { |fragment| fragment.dig("operation", "arguments", "step") }
        refute_includes JSON.generate(fragments.map { |fragment| fragment.fetch("operation") }), "private-"
        assert_balance(connection, external, sync)
        assert_no_difference "IngestionBatch.count" { run_wallet(connection.reload, Sync.find(sync.id)) }
      end
    end
  end

  test "an in-memory cookie cannot authorize crumb before its batch is durably captured" do
    with_wallet do |connection, _external, sync|
      expect_market_prefix
      Wallet::YahooFxReader::Http.expects(:get).once.with { |url, **_args| url == Wallet::YahooFxReader::COOKIE_ENDPOINT }.raises(Net::ReadTimeout)
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      assert_equal 4, connection.ingestion_batches.count
      expect_cookie
      adapter = build(connection, sync)
      cursor = connection.provider_sync_checkpoints.find_by!(stream: "accounts").state.dig("progress", "cursor")
      page = adapter.list_accounts(cursor: cursor)
      assert_equal 4, connection.ingestion_batches.count
      refute_includes page.progress_cursor, "private-"
      refute_includes page.inspect, "private-"
      assert_raises(Provider::AccountData::StaleWriter) { adapter.list_accounts(cursor: page.progress_cursor) }
      assert_equal 4, connection.ingestion_batches.count
    end
  end

  test "private references reject foreign index digest and scope before lending captured credentials" do
    with_wallet do |connection, _external, sync|
      expect_market_prefix
      expect_cookie(interrupt: true)
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
      adapter = build(connection, sync)
      feeder = adapter.instance_variable_get(:@feeder)
      operation = feeder.instance_variable_get(:@assembly).next_operation
      [ { "index" => 0 }, { "index" => 999 }, { "sha256" => "0" * 64 } ].each do |change|
        altered = operation.deep_dup
        altered.fetch("arguments").fetch("auth_refs").fetch("cookie").merge!(change)
        assert_raises(Provider::AccountData::StaleWriter) { feeder.send(:private_auth_for, altered) }
      end
      original_scope = feeder.instance_variable_get(:@scope)
      feeder.instance_variable_set(:@scope, original_scope.merge("family_id" => SecureRandom.uuid))
      assert_raises(Provider::AccountData::StaleWriter) { feeder.send(:private_auth_for, operation) }
    end
  end

  test "expired committed cookie creates a local disposition then bounded fresh auth at the original rate date" do
    with_wallet do |connection, external, sync|
      expect_market_prefix
      expect_cookie(interrupt: true)
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      Provider::AccountData::RequestGrant.unstub(:verify_capture!)
      travel 2.days
      expect_cookie(generation: 1)
      expect_crumb(generation: 1)
      expect_chart(generation: 1)
      run_wallet(connection.reload, Sync.find(sync.id))
      fragments = archive(connection, sync).fetch("fragments").select { |fragment| fragment.dig("operation", "action") == "fx_yahoo" }
      assert_equal %w[cookie crumb cookie crumb chart], fragments.map { |fragment| fragment.dig("operation", "arguments", "step") }
      expired = fragments[1].fetch("response")
      assert_equal "auth_expired", expired.fetch("status")
      assert_nil expired.fetch("http_status")
      assert_equal "2026-09-17", Time.iso8601(expired.fetch("requested_at")).utc.to_date.iso8601
      assert_equal "2026-09-15", expired.dig("request", "date")
      assert_equal 1, fragments.last.dig("operation", "arguments", "auth_generation")
      assert_equal 10, connection.ingestion_batches.count
      assert_balance(connection, external, sync)
    end
  end

  test "Yahoo endpoint or header drift rejects before HTTP and after a captured response" do
    with_wallet do |connection, _external, sync|
      adapter = build(connection, sync)
      original_endpoint = @configuration.fetch("fx").fetch("endpoint")
      @configuration["fx"]["endpoint"] = "https://changed.example.test"
      assert_raises(Provider::AccountData::StaleWriter) do
        adapter.request_grant.capture_request(scope_sync: sync) { flunk "Stale Yahoo endpoint reached HTTP" }
      end
      @configuration["fx"]["endpoint"] = original_endpoint
      expect_market_prefix
      expect_cookie { @configuration["fx"]["user_agent"] = "changed-agent" }
      assert_raises(Provider::AccountData::Error) { run_wallet(connection, sync) }
      refute connection.provider_sync_checkpoints.find_by!(stream: "accounts").covered_through
      assert connection.ingestion_batches.where(status: "applied").all? { |batch| Ingestion::Codec.load(batch.payload).evidence.dig("onchain_capture", "fragment", "operation", "action") != "fx_yahoo" }
    end
  end

  private
    def with_wallet
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "onchain_wallet", credentials: {})
        source = wallet_source(currency: "EUR")
        external = create_external_account(connection, external_id: source[:external][:external_id], name: "Selected", currency: "EUR",
          account_type: "Crypto", sensitive_details: source[:external][:sensitive_details])
        sync = connection.syncs.create!(status: "syncing")
        yield connection, external, sync
      ensure
        if connection
          ProviderConnection.where(id: connection.id).update_all(lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
          ProviderSyncCheckpoint.where(provider_connection_id: connection.id).delete_all
          IngestionBatch.where(provider_connection_id: connection.id).delete_all
          ExternalAccount.where(provider_connection_id: connection.id).delete_all
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all
          ProviderConnection.where(id: connection.id).delete_all
        end
      end
    end

    def expect_market_prefix
      Provider::MempoolSpace.expects(:get).once.with { |url, **_args| url.end_with?(BITCOIN_ADDRESS) }
        .returns(stub(code: 200, body: JSON.generate(bitcoin_summary)))
      Provider::MempoolSpace.expects(:get).once.with { |url, **_args| url.end_with?("/txs") }.returns(stub(code: 200, body: "[]"))
      Wallet::Client::PublicHttp.expects(:get).once.returns(stub(code: 200, body: JSON.generate(daily_quote(date: "2026-09-15").fetch("rows"))))
      Wallet::CachedExchangeRateResolver.any_instance.expects(:call).once.returns(nil)
    end

    def expect_cookie(generation: 0, interrupt: false, &during_request)
      Wallet::YahooFxReader::Http.expects(:get).once.with do |url, **_args|
        next false unless url == Wallet::YahooFxReader::COOKIE_ENDPOINT
        assert_equal 0, ApplicationRecord.connection.open_transactions
        interrupt_after_capture! if interrupt
        during_request&.call
        true
      end.returns(stub(code: 404, body: "", headers: { "set-cookie" => "A3=private-cookie-#{generation}; Max-Age=3600; Secure" }))
    end

    def expect_crumb(generation: 0, interrupt: false)
      Wallet::YahooFxReader::Http.expects(:get).once.with do |url, **args|
        next false unless url.end_with?("/v1/test/getcrumb") && args.dig(:headers, "Cookie") == "A3=private-cookie-#{generation}"
        assert_equal 0, ApplicationRecord.connection.open_transactions
        interrupt_after_capture! if interrupt
        true
      end.returns(stub(code: 200, body: "private-crumb-#{generation}"))
    end

    def expect_chart(generation: 0, interrupt: false)
      Wallet::YahooFxReader::Http.expects(:get).once.with do |url, **args|
        next false unless url.end_with?("/USDEUR%3DX") && args.dig(:query, :crumb) == "private-crumb-#{generation}" &&
          args.dig(:query, :period1) == Time.utc(2026, 9, 5).to_i && args.dig(:query, :period2) == Time.utc(2026, 9, 16).to_i
        assert_equal 0, ApplicationRecord.connection.open_transactions
        interrupt_after_capture! if interrupt
        true
      end.returns(stub(code: 200, body: JSON.generate("chart" => { "error" => nil, "result" => [ {
        "meta" => { "symbol" => "USDEUR=X" }, "timestamp" => [ Time.utc(2026, 9, 14).to_i ], "indicators" => { "quote" => [ { "close" => [ "0.9" ] } ] }
      } ] })))
    end

    def interrupt_after_capture!
      Provider::AccountData::RequestGrant.stubs(:verify_capture!).raises(IOError, "interrupted after Yahoo capture")
    end

    def build(connection, sync)
      Provider::AccountData::Registry.build(connection.reload, sync: sync.reload, observed_at: sync.created_at)
    end

    def run_wallet(connection, sync)
      Provider::AccountData::Syncer.new(connection).perform_sync(sync)
    end

    def archive(connection, sync)
      Wallet::CaptureArchive.build(connection: connection.reload, sync: sync.reload, observed_at: sync.created_at)
    end

    def assert_balance(connection, external, sync)
      page = build(connection, sync).fetch_balance(account: Ingestion::Record.account(external_id: external.external_id, name: "Selected", currency: "EUR"))
      assert page.complete?
      assert_equal BigDecimal("90000"), page.records.sole[:balance]
      assert_equal "2026-09-14", page.evidence.dig("prices", "current", "fx_date")
      refute_includes JSON.generate(page.evidence), "private-"
    end
end
