require "test_helper"

class Provider::Questrade::IngestionClientTest < ActiveSupport::TestCase
  # A protocol fake, not a persistence implementation. Production must provide
  # database-backed serialization and separately committed intent/credentials.
  class SessionStore
    attr_reader :events, :credentials
    attr_accessor :fail_persistence, :before_lock

    def initialize(credentials)
      @credentials, @events, @pending = credentials, [], false
    end

    def with_session_lock
      before_lock&.call(self)
      events << :lock
      yield self
    end

    def refresh_pending?
      @pending
    end

    def begin_refresh!
      @pending = true
      events << :intent_committed
    end

    def persist_credentials!(values)
      raise "private database error" if fail_persistence
      @credentials = values.deep_dup
      @pending = false
      events << :credentials_committed
    end

    def mark_refresh_uncertain!
      @pending = true
      events << :uncertain_committed
    end
  end

  setup do
    @now = Time.utc(2026, 9, 14, 12)
    @store = SessionStore.new("refresh_token" => "private-old-token", "scope" => "read_acc")
    @client = client
  end

  test "ownership loss after the token response remains an ownership denial without recovery mutation" do
    request = stub_token
    @store.expects(:persist_credentials!).raises(Provider::AccountData::StaleWriter, "original ownership denial")
    @store.expects(:mark_refresh_uncertain!).never

    error = assert_raises(Provider::AccountData::StaleWriter) { @client.get_ingestion_accounts }

    assert_equal "original ownership denial", error.message
    assert_equal "private-old-token", @store.credentials.fetch("refresh_token")
    assert @store.refresh_pending?
    assert_requested request, times: 1
    assert_not_requested :get, "https://api01.iq.questrade.com/v1/accounts"
  end

  test "rotation commits intent and all new credentials before the first financial read" do
    token_request = stub_token
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts")
      .with do |request|
        assert_equal [ :lock, :intent_committed, :credentials_committed ], @store.events
        assert_equal "Bearer private-access-token", request.headers["Authorization"]
        true
      end.to_return(status: 200, body: '{"accounts":[]}')
    assert_equal [], @client.get_ingestion_accounts[:accounts]
    assert_equal "private-new-token", @store.credentials["refresh_token"]
    assert_equal "2026-09-14T12:30:00.000000Z", @store.credentials["expires_at"]
    assert_equal "read_acc", @store.credentials["scope"]
    assert_requested token_request, times: 1
    refute_includes @client.inspect, "private"
  end

  test "subsequent clients reuse the latest committed access token without consuming a refresh token" do
    stub_token
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts").to_return(status: 200, body: '{"accounts":[]}')
    @client.get_ingestion_accounts
    client.get_ingestion_accounts
    assert_requested :post, Provider::Questrade::LOGIN_URL, times: 1
  end

  test "the locked current refresh token wins over any stale factory input" do
    @store.before_lock = ->(session) { session.credentials["refresh_token"] = "fresh-token-under-lock" }
    stub_token(refresh_token: "fresh-token-under-lock")
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts").to_return(status: 200, body: '{"accounts":[]}')
    @client.get_ingestion_accounts
  end

  test "an uncertain exchange is never retried by this or a new worker" do
    request = stub_request(:post, Provider::Questrade::LOGIN_URL).to_raise(Net::ReadTimeout.new("private-token"))
    error = assert_raises(Provider::Questrade::AuthenticationError) { @client.get_ingestion_accounts }
    assert_equal :refresh_uncertain, error.error_type
    assert @store.refresh_pending?
    assert_raises(Provider::Questrade::AuthenticationError) { client.get_ingestion_accounts }
    assert_requested request, times: 1
    refute_includes error.message, "private-token"
    assert_nil error.cause
  end

  test "a worker crash after intent leaves later workers unable to reuse the token" do
    @store.begin_refresh!
    HTTParty.expects(:post).never
    assert_raises(Provider::Questrade::AuthenticationError) { @client.get_ingestion_accounts }
  end

  test "persistence failure prevents authenticated reads with memory-only rotated credentials" do
    @store.fail_persistence = true
    stub_token
    HTTParty.expects(:get).never
    error = assert_raises(Provider::Questrade::AuthenticationError) { @client.get_ingestion_accounts }
    assert @store.refresh_pending?
    assert_equal "private-old-token", @store.credentials["refresh_token"]
    refute_includes error.message, "database"
    assert_nil error.cause
  end

  test "refresh rejection malformed response and redirect all leave a recovery marker" do
    [ [ 400, "private-error" ], [ 200, '{"refresh_token":"private-new-token"}' ], [ 307, "" ] ].each do |status, body|
      store = SessionStore.new("refresh_token" => "private-old-token")
      request = stub_request(:post, Provider::Questrade::LOGIN_URL)
        .to_return(status: status, body: body, headers: { "Location" => "https://attacker.invalid/token" })
      assert_raises(Provider::Questrade::AuthenticationError) { client(store: store).get_ingestion_accounts }
      assert store.refresh_pending?
      remove_request_stub(request)
    end
    assert_not_requested :post, "https://attacker.invalid/token"
  end

  test "cached malicious API server cannot receive a bearer token" do
    %w[http://api01.iq.questrade.com https://api01.iq.questrade.com.attacker.invalid https://user:pass@api01.iq.questrade.com https://api01.iq.questrade.com/private].each do |server|
      store = SessionStore.new(cached_credentials.merge("api_server" => server))
      assert_raises(Provider::Questrade::ConfigurationError) { client(store: store).get_ingestion_accounts }
    end
  end

  test "API server with a v1 suffix is normalized once and money remains exact" do
    store = SessionStore.new(cached_credentials.merge("api_server" => "https://api01.iq.questrade.com/v1/"))
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts/123/positions")
      .to_return(status: 200, body: '{"positions":[{"currentPrice":1.234567890123456789}]}')
    value = client(store: store).get_ingestion_holdings(account_id: "123")
    assert_equal BigDecimal("1.234567890123456789"), value[:positions].first[:currentPrice]
  end

  test "403 is a missing account-read scope and never triggers another refresh" do
    store = SessionStore.new(cached_credentials)
    HTTParty.expects(:post).never
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts").to_return(status: 403, body: "private-denial")
    error = assert_raises(Provider::Questrade::AuthenticationError) { client(store: store).get_ingestion_accounts }
    assert_equal :insufficient_scope, error.error_type
    refute_includes error.message, "private-denial"
  end

  test "a 401 can use a concurrently refreshed stored access token without rotating again" do
    store = SessionStore.new(cached_credentials)
    store.before_lock = lambda do |session|
      session.credentials["access_token"] = "concurrent-access" if session.events.include?(:lock)
    end
    HTTParty.expects(:post).never
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts").with(headers: { "Authorization" => "Bearer cached-access" })
      .to_return(status: 401, body: "")
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts").with(headers: { "Authorization" => "Bearer concurrent-access" })
      .to_return(status: 200, body: '{"accounts":[]}')
    assert_equal [], client(store: store).get_ingestion_accounts[:accounts]
  end

  test "bounded activity requests and symbol batches reject unsafe input before authentication" do
    HTTParty.expects(:post).never
    assert_raises(Provider::Questrade::Error) { @client.get_ingestion_activities(account_id: "123", start_time: "2026-08-01T00:00:00Z", end_time: "2026-09-14T00:00:00Z") }
    assert_raises(Provider::Questrade::Error) { @client.get_ingestion_holdings(account_id: "123/../456") }
    assert_raises(Provider::Questrade::Error) { @client.get_ingestion_symbols(ids: Array.new(101, "1")) }
  end

  test "missing or partial collections are errors while an explicit empty collection is valid" do
    store = SessionStore.new(cached_credentials)
    [ '{}', '{"accounts":null}', '{"accounts":[],"hasMore":true}', '{"accounts":[],"totalCount":1}' ].each do |body|
      stub_request(:get, "https://api01.iq.questrade.com/v1/accounts").to_return(status: 200, body: body)
      assert_raises(Provider::Questrade::Error) { client(store: store).get_ingestion_accounts }
    end
  end

  test "safe data reads retry transport errors a bounded number of times without rotating" do
    store = SessionStore.new(cached_credentials)
    reader = client(store: store)
    reader.stubs(:sleep)
    HTTParty.expects(:post).never
    stub_request(:get, "https://api01.iq.questrade.com/v1/accounts").to_raise(Net::ReadTimeout)
    error = assert_raises(Provider::Questrade::Error) { reader.get_ingestion_accounts }
    assert_equal :network_error, error.error_type
    assert_requested :get, "https://api01.iq.questrade.com/v1/accounts", times: 4
  end

  test "practice credentials cannot silently cross to the live authentication realm" do
    store = SessionStore.new(cached_credentials.merge("environment" => "practice"))
    HTTParty.expects(:post).never
    assert_raises(Provider::Questrade::ConfigurationError) { client(store: store).get_ingestion_accounts }
  end

  private
    def client(store: @store)
      Provider::Questrade::IngestionClient.new(credential_store: store, clock: -> { @now })
    end

    def cached_credentials
      { "refresh_token" => "stored-refresh", "access_token" => "cached-access", "api_server" => "https://api01.iq.questrade.com/",
        "expires_at" => (@now + 1800).iso8601, "environment" => "live" }
    end

    def stub_token(refresh_token: "private-old-token")
      stub_request(:post, Provider::Questrade::LOGIN_URL).with(body: { grant_type: "refresh_token", refresh_token: refresh_token })
        .to_return(status: 200, body: { access_token: "private-access-token", refresh_token: "private-new-token",
          expires_in: 1800, token_type: "Bearer", api_server: "https://api01.iq.questrade.com/" }.to_json)
    end
end
