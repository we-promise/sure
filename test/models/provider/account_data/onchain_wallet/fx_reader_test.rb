require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::OnchainWallet::FxReaderTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Wallet = Provider::AccountData::OnchainWallet

  setup do
    @date = Date.new(2026, 9, 15)
    @http = mock("one bounded FX response")
  end

  test "Twelve Data captures exact decimal rate and actual timestamp with the captured key" do
    reader = build("twelve_data", key: "private-api-key")
    @http.expects(:get).once.with("https://fx.example.test/exchange_rate", query: { symbol: "USD/EUR", date: @date.iso8601, timezone: "UTC" },
      headers: { "Authorization" => "apikey private-api-key" }, follow_redirects: false)
      .returns(stub(code: 200, body: '{"symbol":"USD/EUR","rate":0.891234567890123456,"timestamp":1789344000}'))
    capture = reader.read(from: "USD", to: "EUR", date: @date)
    value = Wallet::FxReader.rate(capture, from: "USD", to: "EUR", date: @date, provider: "twelve_data")
    assert_equal "0.891234567890123456", value.fetch("rate")
    assert_equal Time.at(1789344000).utc.to_date.iso8601, value.fetch("date")
    refute_equal @date.iso8601, value.fetch("date")
    refute_includes JSON.generate(capture), "private-api-key"
    refute_includes reader.inspect, "private-api-key"
  end

  test "Frankfurter requires requested pair and preserves previous trading day" do
    @http.expects(:get).once.with("https://fx.example.test/rate/USD/EUR", query: { date: @date.iso8601 }, follow_redirects: false)
      .returns(stub(code: 200, body: '{"base":"USD","quote":"EUR","date":"2026-09-14","rate":0.9}'))
    capture = build("frankfurter").read(from: "USD", to: "EUR", date: @date)
    assert_equal({ "rate" => "0.9", "date" => "2026-09-14", "source" => "provider_response", "provider" => "frankfurter" },
      Wallet::FxReader.rate(capture, from: "USD", to: "EUR", date: @date, provider: "frankfurter"))
    assert_nil Wallet::FxReader.rate(capture, from: "EUR", to: "USD", date: @date, provider: "frankfurter")
    assert_nil Wallet::FxReader.rate(capture, from: "USD", to: "EUR", date: @date, provider: "twelve_data")
  end

  test "missing contradictory future stale and nonpositive values cannot relabel the requested day" do
    bodies = [
      { "symbol" => "USD/EUR", "rate" => "0.9" },
      { "symbol" => "USD/EUR", "rate" => "0.9", "date" => "2026-09-14", "timestamp" => Time.utc(2026, 9, 15).to_i },
      { "symbol" => "USD/EUR", "rate" => "0.9", "timestamp" => Time.utc(2026, 9, 16).to_i },
      { "symbol" => "USD/EUR", "rate" => "0.9", "timestamp" => Time.utc(2026, 9, 9).to_i },
      { "symbol" => "EUR/USD", "rate" => "0.9", "date" => @date.iso8601 },
      { "symbol" => "USD/EUR", "rate" => "0", "date" => @date.iso8601 },
      { "symbol" => "USD/EUR", "rate" => "NaN", "date" => @date.iso8601 }
    ]
    bodies.each do |body|
      @http.expects(:get).once.returns(stub(code: 200, body: JSON.generate(body)))
      capture = build("twelve_data", key: "key").read(from: "USD", to: "EUR", date: @date)
      assert_nil Wallet::FxReader.rate(capture, from: "USD", to: "EUR", date: @date, provider: "twelve_data")
    end
  end

  test "authentication redirect and terminal provider errors are captured once without sensitive messages" do
    [ [ 401, "authentication_failed" ], [ 302, "request_failed" ], [ 404, "request_failed" ] ].each do |code, status|
      @http.expects(:get).once.returns(stub(code: code, body: "private-api-key", headers: { location: "https://elsewhere" }))
      capture = build("twelve_data", key: "private-api-key").read(from: "USD", to: "EUR", date: @date)
      assert_equal status, capture.fetch("status")
      assert_empty capture.fetch("response")
      refute_includes JSON.generate(capture), "private-api-key"
    end
    @http.expects(:get).once.returns(stub(code: 200, body: '{"code":400,"message":"private-api-key","status":"error"}'))
    capture = build("twelve_data", key: "private-api-key").read(from: "USD", to: "EUR", date: @date)
    assert_equal "request_failed", capture.fetch("status")
    refute_includes JSON.generate(capture), "private-api-key"
  end

  test "HTTP and JSON throttles and server failures escape without hidden retry or permanent unavailable receipt" do
    [ [ 429, nil, Wallet::Readers::RateLimited ], [ 503, nil, Wallet::Readers::Error ],
      [ 200, 429, Wallet::Readers::RateLimited ], [ 200, 500, Wallet::Readers::Error ] ].each do |http_code, json_code, error_class|
      @http.expects(:get).once.returns(stub(code: http_code, body: JSON.generate(code: json_code, message: "private-api-key")))
      error = assert_raises(error_class) { build("twelve_data", key: "private-api-key").read(from: "USD", to: "EUR", date: @date) }
      refute_includes error.message, "private-api-key"
      assert_nil error.cause
    end
  end

  test "oversized malformed and transport failures never create a guessed exchange rate" do
    [ "not-json", " " * (Wallet::FxReader::MAX_BYTES + 1), "[]" ].each do |body|
      @http.expects(:get).once.returns(stub(code: 200, body: body))
      capture = build("frankfurter").read(from: "USD", to: "EUR", date: @date)
      assert_equal "invalid_response", capture.fetch("status")
      assert_nil Wallet::FxReader.rate(capture, from: "USD", to: "EUR", date: @date, provider: "frankfurter")
    end
    @http.expects(:get).once.raises(Net::ReadTimeout, "private-endpoint")
    error = assert_raises(Wallet::Readers::Error) { build("frankfurter").read(from: "USD", to: "EUR", date: @date) }
    refute_includes error.message, "private-endpoint"
    assert_nil error.cause
  end

  test "missing credentials and unsupported providers remain explicit without network or provider switching" do
    @http.expects(:get).never
    capture = build("twelve_data").read(from: "USD", to: "EUR", date: @date)
    assert_equal "credential_unavailable", capture.fetch("status")
    %w[yahoo_finance moex_public unrecognized].each do |provider|
      capture = build(provider).read(from: "USD", to: "EUR", date: @date)
      assert_equal provider, capture.fetch("provider")
      assert_equal "unsupported_provider", capture.fetch("status")
      assert_nil Wallet::FxReader.rate(capture, from: "USD", to: "EUR", date: @date, provider: provider)
    end
  end

  test "HTTP requires no database transaction and initialization rejects a stale key" do
    @http.expects(:get).never
    reader = build("frankfurter")
    ApplicationRecord.transaction do
      assert_raises(Provider::AccountData::InvalidResponse) { reader.read(from: "USD", to: "EUR", date: @date) }
    end
    options, credentials = configuration("twelve_data", key: "old")
    assert_raises(Provider::AccountData::StaleWriter) do
      Wallet::FxReader.new(options: options, credentials: credentials.merge("api_key" => "new"), http: @http)
    end
  end

  test "fresh encrypted setting and ENV precedence pin factory admission and publication despite stale request cache" do
    with_settings do
      Setting.exchange_rate_provider = "twelve_data"
      Setting.twelve_data_api_key = "first-private-key"
      assert_equal "first-private-key", Setting.twelve_data_api_key
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "onchain_wallet", credentials: {})
        sync = connection.syncs.create!
        Provider::AccountData::Registry.stubs(:fetch).with("onchain_wallet").returns(Wallet)
        factory = -> { Provider::AccountData::Registry.build(connection.reload, sync: sync, observed_at: sync.created_at) }
        original = factory.call
        proof = original.request_grant.snapshot
        refute_includes JSON.generate(proof), "first-private-key"
        update_key_in_another_session("second-private-key")
        assert_equal "first-private-key", Setting.twelve_data_api_key
        assert_equal "second-private-key", Wallet::FxConfiguration.credentials.fetch("api_key")
        assert_raises(Provider::AccountData::StaleWriter) { original.request_grant.capture_request(scope_sync: sync) { flunk "Stale key reached HTTP" } }
        current = factory.call
        _page, capture = current.request_grant.capture_request(scope_sync: sync) do
          update_key_in_another_session("third-private-key")
          Provider::AccountData::Page.new(records: [], complete: true)
        end
        assert_raises(Provider::AccountData::StaleWriter) do
          Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true, scope_sync: sync)
        end
        ENV["TWELVE_DATA_API_KEY"] = "environment-private-key"
        assert_equal "environment-private-key", Wallet::FxConfiguration.credentials.fetch("api_key")
        options = Wallet::FxConfiguration.options
        assert_equal Wallet::FxConfiguration.fingerprint(Wallet::FxConfiguration.credentials), options.fetch("credential_fingerprint")
        refute_includes JSON.generate(options), "environment-private-key"
      ensure
        Sync.where(syncable_type: "ProviderConnection", syncable_id: connection&.id).delete_all
        ProviderConnection.where(id: connection&.id).delete_all
      end
    end
  end

  private
    def configuration(provider, key: nil)
      credentials = { "provider" => provider }
      credentials["api_key"] = key if provider == "twelve_data"
      [ { "version" => 1, "provider" => provider, "endpoint" => "https://fx.example.test", "min_interval_seconds" => "0.4",
        "credential_fingerprint" => Wallet::FxConfiguration.fingerprint(credentials) }, credentials ]
    end

    def build(provider, key: nil)
      options, credentials = configuration(provider, key: key)
      Wallet::FxReader.new(options: options, credentials: credentials, http: @http)
    end

    def with_settings
      keys = %w[exchange_rate_provider twelve_data_api_key]
      rows = Setting.unscoped.where(var: keys).map(&:attributes)
      env = %w[EXCHANGE_RATE_PROVIDER TWELVE_DATA_API_KEY].to_h { |key| [ key, ENV[key] ] }
      env.each_key { |key| ENV.delete(key) }
      family = families(:dylan_family)
      stamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
      yield
    ensure
      Setting.unscoped.where(var: keys).delete_all
      Setting.insert_all!(rows) if rows&.any?
      Setting.clear_cache
      env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      Family.where(id: family&.id).update_all(stamps) if stamps
    end

    def update_key_in_another_session(value)
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do |database|
          database.execute("SET statement_timeout = '5s'")
          begin
            Setting.twelve_data_api_key = value
          ensure
            database.execute("RESET statement_timeout")
            RailsSettings::RequestCache.reset
          end
        end
      end
      assert worker.join(10), "Setting setter must run after factory/request admission releases locks"
      worker.value
    ensure
      worker.kill.join if worker&.alive?
    end
end
