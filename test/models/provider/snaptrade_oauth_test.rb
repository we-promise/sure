require "test_helper"
require "ostruct"

class Provider::SnaptradeOauthTest < ActiveSupport::TestCase
  setup do
    @original = Rails.configuration.x.snaptrade
    Rails.configuration.x.snaptrade = ActiveSupport::OrderedOptions.new
  end

  teardown do
    Rails.configuration.x.snaptrade = @original
  end

  test "oauth_configured? requires both client id and secret" do
    assert_not Provider::Snaptrade.oauth_configured?

    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    assert_not Provider::Snaptrade.oauth_configured?

    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
    assert Provider::Snaptrade.oauth_configured?
  end

  # --- helpers ---
  def configure_oauth!
    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
  end

  def faraday_response(status:, body:)
    OpenStruct.new(status: status, body: body, success?: (200..299).cover?(status))
  end

  def fake_item(access_token: "at-1", refresh_token: "rt-1", expires_at: 1.hour.from_now)
    item = OpenStruct.new(
      oauth_access_token: access_token,
      oauth_refresh_token: refresh_token,
      oauth_token_expires_at: expires_at,
      family: nil
    )
    def item.apply_oauth_tokens!(payload)
      (@applied ||= []) << payload
      self.oauth_access_token = payload["access_token"]
    end
    def item.applied = @applied || []
    def item.update!(attrs) = (@updates ||= []) << attrs
    def item.updates = @updates || []
    # Stand in for ActiveRecord's row-locking API used by Provider::Snaptrade#refresh_access_token!.
    # By default there's nothing concurrent to guard against in these tests, so locking is a no-op
    # and reload leaves attributes untouched (they're already "current" in memory).
    def item.with_lock
      yield
    end
    def item.reload
      self
    end
    item
  end

  test "generate_pkce returns S256 challenge of the verifier" do
    pkce = Provider::Snaptrade.generate_pkce
    expected = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(pkce[:verifier]), padding: false)
    assert_equal expected, pkce[:challenge]
    assert pkce[:verifier].length.between?(43, 128)
  end

  test "authorize_url contains all required OAuth params" do
    configure_oauth!
    url = Provider::Snaptrade.authorize_url(
      redirect_uri: "https://sure.test/callback", state: "st4te", code_challenge: "ch4llenge"
    )
    uri = URI.parse(url)
    params = Rack::Utils.parse_query(uri.query)
    assert_equal "dashboard.snaptrade.com", uri.host
    assert_equal "code", params["response_type"]
    assert_equal "client-id", params["client_id"]
    assert_equal "https://sure.test/callback", params["redirect_uri"]
    assert_equal "read", params["scope"]
    assert_equal "st4te", params["state"]
    assert_equal "ch4llenge", params["code_challenge"]
    assert_equal "S256", params["code_challenge_method"]
  end

  test "exchange_code posts grant with PKCE verifier and basic auth" do
    configure_oauth!
    connection = mock("faraday")
    request = OpenStruct.new(headers: {})
    connection.expects(:post).with(Provider::Snaptrade::TOKEN_URL).yields(request)
      .returns(faraday_response(status: 200, body: { access_token: "at", refresh_token: "rt", expires_in: 900, token_type: "Bearer", scope: "read" }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    payload = Provider::Snaptrade.exchange_code(code: "c0de", redirect_uri: "https://sure.test/cb", code_verifier: "v3rifier")

    assert_equal "at", payload["access_token"]
    assert_equal "Basic #{Base64.strict_encode64('client-id:client-secret')}", request.headers["Authorization"]
    body = Rack::Utils.parse_query(request.body)
    assert_equal "authorization_code", body["grant_type"]
    assert_equal "c0de", body["code"]
    assert_equal "v3rifier", body["code_verifier"]
    assert_equal "https://sure.test/cb", body["redirect_uri"]
  end

  test "token request raises AuthenticationError on 4xx with error description" do
    configure_oauth!
    connection = mock("faraday")
    connection.expects(:post).returns(faraday_response(status: 400, body: { error: "invalid_grant", error_description: "expired" }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    error = assert_raises(Provider::Snaptrade::AuthenticationError) do
      Provider::Snaptrade.refresh_tokens(refresh_token: "dead-rt")
    end
    assert_match "expired", error.message
  end

  test "data calls send Bearer token on API base URL" do
    configure_oauth!
    item = fake_item
    provider = Provider::Snaptrade.new(item)

    request = OpenStruct.new(headers: {}, params: {})
    connection = mock("faraday")
    connection.expects(:get).with("#{Provider::Snaptrade::API_BASE_URL}/api/v1/accounts").yields(request)
      .returns(faraday_response(status: 200, body: [ { id: "acct-1" } ].to_json))
    provider.stubs(:api_connection).returns(connection)

    accounts = provider.list_accounts
    assert_equal "Bearer at-1", request.headers["Authorization"]
    assert_equal [ { "id" => "acct-1" } ], accounts
  end

  test "expired token is refreshed before the data call and rotation persisted" do
    configure_oauth!
    item = fake_item(expires_at: 1.minute.ago)
    provider = Provider::Snaptrade.new(item)

    Provider::Snaptrade.expects(:refresh_tokens).with(refresh_token: "rt-1")
      .returns({ "access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 900 })

    request = OpenStruct.new(headers: {}, params: {})
    connection = mock("faraday")
    connection.expects(:get).yields(request).returns(faraday_response(status: 200, body: "[]"))
    provider.stubs(:api_connection).returns(connection)

    provider.list_accounts
    assert_equal "Bearer at-2", request.headers["Authorization"]
    assert_equal "at-2", item.applied.last["access_token"]
  end

  test "401 triggers one refresh and retry" do
    configure_oauth!
    item = fake_item
    provider = Provider::Snaptrade.new(item)

    Provider::Snaptrade.expects(:refresh_tokens).with(refresh_token: "rt-1")
      .returns({ "access_token" => "at-2", "expires_in" => 900 })

    connection = mock("faraday")
    responses = [ faraday_response(status: 401, body: "{}"), faraday_response(status: 200, body: "[]") ]
    connection.expects(:get).twice.yields(OpenStruct.new(headers: {}, params: {})).returns(*responses)
    provider.stubs(:api_connection).returns(connection)

    assert_equal [], provider.list_accounts
  end

  test "failed refresh marks item requires_update and raises AuthenticationError" do
    configure_oauth!
    item = fake_item(expires_at: 1.minute.ago)
    provider = Provider::Snaptrade.new(item)
    DebugLogEntry.stubs(:capture)

    Provider::Snaptrade.expects(:refresh_tokens).raises(Provider::Snaptrade::AuthenticationError, "invalid_grant")

    assert_raises(Provider::Snaptrade::AuthenticationError) { provider.list_accounts }
    assert_includes item.updates, { status: :requires_update }
  end

  test "blank refresh token raises AuthenticationError and marks requires_update exactly once" do
    configure_oauth!
    item = fake_item(refresh_token: nil, expires_at: 1.minute.ago)
    provider = Provider::Snaptrade.new(item)
    DebugLogEntry.stubs(:capture)

    assert_raises(Provider::Snaptrade::AuthenticationError) { provider.list_accounts }
    assert_equal [ { status: :requires_update } ], item.updates
  end

  test "concurrent refresh race: reload inside lock finds already-fresh token and skips HTTP refresh" do
    configure_oauth!
    item = fake_item(access_token: "at-stale", expires_at: 1.minute.ago)
    # Simulate a concurrent caller having already rotated the tokens in the DB by the time
    # this caller acquires the row lock and reloads -- the in-memory copy looked expired,
    # but the reloaded row is fresh.
    def item.reload
      self.oauth_access_token = "at-fresh"
      self.oauth_token_expires_at = 1.hour.from_now
      self
    end
    provider = Provider::Snaptrade.new(item)

    Provider::Snaptrade.expects(:refresh_tokens).never

    request = OpenStruct.new(headers: {}, params: {})
    connection = mock("faraday")
    connection.expects(:get).yields(request).returns(faraday_response(status: 200, body: "[]"))
    provider.stubs(:api_connection).returns(connection)

    assert_equal [], provider.list_accounts
    assert_equal "Bearer at-fresh", request.headers["Authorization"]
  end

  test "get_connection_url posts login and returns redirect URI" do
    configure_oauth!
    provider = Provider::Snaptrade.new(fake_item)

    request = OpenStruct.new(headers: {}, params: {})
    connection = mock("faraday")
    connection.expects(:post).with("#{Provider::Snaptrade::API_BASE_URL}/api/v1/snapTrade/login").yields(request)
      .returns(faraday_response(status: 200, body: { redirectURI: "https://app.snaptrade.com/connect/xyz" }.to_json))
    provider.stubs(:api_connection).returns(connection)

    url = provider.get_connection_url(redirect_url: "https://sure.test/return", broker: "QUESTRADE")
    assert_equal "https://app.snaptrade.com/connect/xyz", url
    body = JSON.parse(request.body)
    assert_equal "https://sure.test/return", body["customRedirect"]
    assert_equal "read", body["connectionType"]
    assert_equal "QUESTRADE", body["broker"]
  end
end
