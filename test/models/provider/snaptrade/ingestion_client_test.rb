require "test_helper"

class Provider::Snaptrade::IngestionClientTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 1, 15, 12)
    @store = TokenStore.new({ "oauth_access_token" => "access-token", "oauth_refresh_token" => "refresh-token",
      "oauth_token_expires_at" => (@now + 3600).iso8601, "consumer_key" => "preserved-deprecated-secret" })
    @client = build_client
  end

  test "one canonical data request retains exact decimals and sends bearer credentials only in headers" do
    request = stub_request(:get, "https://api.snaptrade.com/accounts/account-1/balances")
      .with(headers: { "Authorization" => "Bearer access-token", "Accept" => "application/json" })
      .to_return(status: 200, body: '[{"currency":{"code":"USD"},"cash":123456789.123456789012345678}]')
    response = @client.balances_snapshot(account_id: "account-1")
    assert_equal BigDecimal("123456789.123456789012345678"), response.sole.fetch("cash")
    assert_requested request, times: 1
    assert_equal [ :lock, :unlock ], @store.events
    assert_not_includes @client.inspect, "token"
  end

  test "bounded activities preserve explicit inclusive dates offset and page size" do
    request = stub_request(:get, "https://api.snaptrade.com/accounts/account-1/activities")
      .with(query: { startDate: "2020-01-01", endDate: "2026-01-15", offset: "500", limit: "500" })
      .to_return(status: 200, body: '{"data":[],"pagination":{"offset":500,"limit":500,"total":500}}')
    result = @client.activities_page(account_id: "account-1", start_date: "2020-01-01", end_date: "2026-01-15", offset: 500)
    assert_equal 500, result.fetch("pagination").fetch("total")
    assert_requested request, times: 1
    assert_raises(ArgumentError) { @client.activities_page(account_id: "account-1", start_date: "2026-02-01", end_date: "2026-01-15") }
    assert_raises(ArgumentError) { @client.activities_page(account_id: "account-1", start_date: "2020-01-01", end_date: "2026-01-15", offset: -1) }
    assert_raises(ArgumentError) { @client.positions_snapshot(account_id: "../other?private=secret") }
  end

  test "proactive confidential rotation commits intent and replacement before using the new access token" do
    @store.values["oauth_token_expires_at"] = (@now + 30).iso8601
    token = stub_request(:post, Provider::Snaptrade::TOKEN_URL)
      .with(headers: { "Authorization" => "Basic #{Base64.strict_encode64('application-id:application-secret')}" },
        body: { grant_type: "refresh_token", refresh_token: "refresh-token" })
      .to_return do
        assert_equal [ :lock, :begin_refresh ], @store.events
        { status: 200, body: '{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":7200,"token_type":"Bearer","scope":"read"}' }
      end
    data = stub_request(:get, "https://api.snaptrade.com/accounts")
      .with(headers: { "Authorization" => "Bearer new-access" })
      .to_return do
        assert_includes @store.events, :persist
        assert_equal "rotated-refresh", @store.values.fetch("oauth_refresh_token")
        { status: 200, body: "[]" }
      end
    assert_empty @client.accounts_snapshot
    assert_requested token, times: 1
    assert_requested data, times: 1
    assert_equal (@now + 7200).iso8601(9), @store.values.fetch("oauth_token_expires_at")
    assert_equal "read", @store.values.fetch("oauth_scope")
    assert_equal "Bearer", @store.values.fetch("oauth_token_type")
    assert_equal "preserved-deprecated-secret", @store.values.fetch("consumer_key")
    assert_equal [ :lock, :begin_refresh, :persist, :unlock ], @store.events
  end

  test "public OAuth client rotation retains omitted refresh scope type and expiry fields" do
    @store.values.merge!("oauth_scope" => "old-scope", "oauth_token_type" => "Bearer", "oauth_token_expires_at" => (@now + 30).iso8601)
    old_expiry = @store.values.fetch("oauth_token_expires_at")
    client = build_client(oauth_client_secret: nil)
    token = stub_request(:post, Provider::Snaptrade::TOKEN_URL)
      .with(body: { grant_type: "refresh_token", refresh_token: "refresh-token", client_id: "application-id" })
      .to_return(status: 200, body: '{"access_token":"new-access"}')
    stub_request(:get, "https://api.snaptrade.com/authorizations").with(headers: { Authorization: "Bearer new-access" }).to_return(status: 200, body: "[]")
    client.authorizations_snapshot
    assert_requested token, times: 1
    assert_equal "refresh-token", @store.values.fetch("oauth_refresh_token")
    assert_equal "old-scope", @store.values.fetch("oauth_scope")
    assert_equal "Bearer", @store.values.fetch("oauth_token_type")
    assert_equal old_expiry, @store.values.fetch("oauth_token_expires_at")
  end

  test "a reactive 401 uses a concurrent winner instead of rotating the rejected token again" do
    first = stub_request(:get, "https://api.snaptrade.com/accounts")
      .with(headers: { Authorization: "Bearer access-token" })
      .to_return do
        @store.values["oauth_access_token"] = "winner-access"
        { status: 401, body: "{}" }
      end
    second = stub_request(:get, "https://api.snaptrade.com/accounts")
      .with(headers: { Authorization: "Bearer winner-access" }).to_return(status: 200, body: "[]")
    assert_empty @client.accounts_snapshot
    assert_requested first, times: 1
    assert_requested second, times: 1
    assert_not_requested :post, Provider::Snaptrade::TOKEN_URL
    assert_equal [ :lock, :unlock, :lock, :unlock ], @store.events
  end

  test "a reactive rejection rotates despite a locally unexpired token and retries GET only once" do
    stub_request(:get, "https://api.snaptrade.com/accounts").with(headers: { Authorization: "Bearer access-token" }).to_return(status: 401, body: "{}")
    token = stub_request(:post, Provider::Snaptrade::TOKEN_URL).to_return(status: 200, body: '{"access_token":"rotated","expires_in":3600}')
    retried = stub_request(:get, "https://api.snaptrade.com/accounts").with(headers: { Authorization: "Bearer rotated" }).to_return(status: 401, body: '{"error":"private detail"}')
    error = assert_raises(Provider::Snaptrade::AuthenticationError) { @client.accounts_snapshot }
    assert_not_includes error.message, "private detail"
    assert_requested token, times: 1
    assert_requested retried, times: 1
  end

  test "lost rotation response leaves committed uncertainty and is never retried" do
    @store.values["oauth_token_expires_at"] = (@now - 1).iso8601
    request = stub_request(:post, Provider::Snaptrade::TOKEN_URL).to_timeout
    error = assert_raises(Provider::Snaptrade::AuthenticationError) { @client.accounts_snapshot }
    assert_nil error.cause
    assert_equal true, @store.pending
    assert_includes @store.events, :uncertain
    assert_equal "access-token", @store.values.fetch("oauth_access_token")
    assert_raises(Provider::AccountData::CredentialStore::ReauthorizationRequired) { @client.accounts_snapshot }
    assert_requested request, times: 1
    assert_not_requested :get, "https://api.snaptrade.com/accounts"
  end

  test "replacement persistence failure cannot release an uncommitted access token" do
    @store.values["oauth_token_expires_at"] = (@now - 1).iso8601
    @store.fail_persist = true
    request = stub_request(:post, Provider::Snaptrade::TOKEN_URL).to_return(status: 200, body: '{"access_token":"not-committed","expires_in":3600}')
    assert_raises(Provider::Snaptrade::AuthenticationError) { @client.accounts_snapshot }
    assert_requested request, times: 1
    assert_equal "access-token", @store.values.fetch("oauth_access_token")
    assert_not_requested :get, "https://api.snaptrade.com/accounts"
  end

  test "deprecated credentials require reconnection and remain untouched" do
    @store.values.delete("oauth_access_token")
    before = @store.values.deep_dup
    assert_raises(Provider::Snaptrade::AuthenticationError) { @client.accounts_snapshot }
    assert_equal before, @store.values
    assert_not_requested :post, Provider::Snaptrade::TOKEN_URL
    assert_not_requested :get, "https://api.snaptrade.com/accounts"
  end

  test "invalid responses and network errors do not expose credential or provider bodies" do
    request = stub_request(:get, "https://api.snaptrade.com/accounts").to_return(status: 500, body: "access-token private response")
    error = assert_raises(Provider::Snaptrade::ApiError) { @client.accounts_snapshot }
    assert_equal 500, error.status_code
    assert_nil error.response_body
    assert_not_includes error.message, "access-token"
    remove_request_stub(request)
    request = stub_request(:get, "https://api.snaptrade.com/accounts").to_return(status: 200, body: "refresh-token invalid JSON")
    error = assert_raises(Provider::Snaptrade::ApiError) { @client.accounts_snapshot }
    assert_nil error.cause
    assert_not_includes error.message, "refresh-token"
    remove_request_stub(request)
    stub_request(:get, "https://api.snaptrade.com/accounts").to_timeout
    error = assert_raises(Provider::Snaptrade::ApiError) { @client.accounts_snapshot }
    assert_nil error.cause
    assert_not_includes error.message, "access-token"
  end

  private
    def build_client(**options)
      Provider::Snaptrade::IngestionClient.new(credential_store: @store, oauth_client_id: "application-id",
        oauth_client_secret: "application-secret", clock: -> { @now }, **options)
    end

    # An explicit state machine double verifies ordering and abandoned intent.
    # Shared store tests cover PostgreSQL lock/revision/tenant implementation.
    class TokenStore
      attr_accessor :values, :pending, :fail_persist
      attr_reader :events

      def initialize(values)
        @values, @pending, @events = values, false, []
      end

      def with_session_lock
        events << :lock
        yield self
      ensure
        events << :unlock
      end

      def credentials
        values.deep_dup
      end

      def refresh_pending?
        pending
      end

      def begin_refresh!
        raise "intent exists" if pending
        self.pending = true
        events << :begin_refresh
      end

      def persist_credentials!(replacement)
        raise "storage unavailable" if fail_persist
        raise "intent missing" unless pending
        self.values = replacement
        self.pending = false
        events << :persist
      end

      def mark_refresh_uncertain!
        raise "intent missing" unless pending
        events << :uncertain
      end
    end
end
