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

  test "oauth_configured? needs only the public client id, the redirect flow needs the secret too" do
    assert_not Provider::Snaptrade.oauth_configured?
    assert_not Provider::Snaptrade.authorization_code_configured?

    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    assert Provider::Snaptrade.oauth_configured?
    assert_not Provider::Snaptrade.authorization_code_configured?

    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
    assert Provider::Snaptrade.oauth_configured?
    assert Provider::Snaptrade.authorization_code_configured?
  end

  test "the redirect flow refuses to start without a confidential client" do
    configure_device_flow_only!

    assert_raises(Provider::Snaptrade::ConfigurationError) do
      Provider::Snaptrade.authorize_url(redirect_uri: "https://sure.test/cb", state: "s", code_challenge: "c")
    end

    assert_raises(Provider::Snaptrade::ConfigurationError) do
      Provider::Snaptrade.exchange_code(code: "c0de", redirect_uri: "https://sure.test/cb", code_verifier: "v")
    end
  end

  # --- helpers ---
  def configure_oauth!
    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = "client-secret"
  end

  # A deployment that registered only a public OAuth client: device flow only.
  def configure_device_flow_only!
    Rails.configuration.x.snaptrade.oauth_client_id = "client-id"
    Rails.configuration.x.snaptrade.oauth_client_secret = nil
  end

  def discovery_body
    {
      device_authorization_endpoint: "https://api.snaptrade.com/oauth/device_authorization/",
      token_endpoint: Provider::Snaptrade::TOKEN_URL
    }.to_json
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

  test "get_positions calls /positions/all and unwraps results" do
    configure_oauth!
    provider = Provider::Snaptrade.new(fake_item)

    request = OpenStruct.new(headers: {}, params: {})
    body = {
      results: [ { instrument: { kind: "stock", symbol: "AAPL" }, units: "10", price: "1.5" } ],
      data_freshness: { as_of: "2026-08-14T18:12:18Z" }
    }.to_json

    connection = mock("faraday")
    connection.expects(:get)
      .with("#{Provider::Snaptrade::API_BASE_URL}/api/v1/accounts/acct-1/positions/all")
      .yields(request).returns(faraday_response(status: 200, body: body))
    provider.stubs(:api_connection).returns(connection)

    positions = provider.get_positions(account_id: "acct-1")

    assert_equal 1, positions.size
    assert_equal "AAPL", positions.first.dig("instrument", "symbol")
  end

  test "get_positions returns an empty array for an account holding nothing" do
    configure_oauth!
    provider = Provider::Snaptrade.new(fake_item)

    connection = mock("faraday")
    connection.expects(:get).yields(OpenStruct.new(headers: {}, params: {}))
      .returns(faraday_response(status: 200, body: { results: [] }.to_json))
    provider.stubs(:api_connection).returns(connection)

    assert_equal [], provider.get_positions(account_id: "acct-1")
  end

  test "get_positions raises rather than reporting no positions when results are absent" do
    configure_oauth!
    provider = Provider::Snaptrade.new(fake_item)

    connection = mock("faraday")
    connection.expects(:get).yields(OpenStruct.new(headers: {}, params: {}))
      .returns(faraday_response(status: 200, body: { data_freshness: {} }.to_json))
    provider.stubs(:api_connection).returns(connection)

    error = assert_raises(Provider::Snaptrade::ApiError) do
      provider.get_positions(account_id: "acct-1")
    end
    assert_match "no results array", error.message
  end

  test "get_positions filters out instrument kinds the holdings pipeline cannot model" do
    configure_oauth!
    provider = Provider::Snaptrade.new(fake_item)

    body = {
      results: [
        { instrument: { kind: "stock", symbol: "AAPL" }, units: "10", price: "1.5" },
        { instrument: { kind: "option", symbol: "AAPL 240119C00150000" }, units: "2", price: "5.1" },
        { instrument: { kind: "future", symbol: "ESZ4" }, units: "1", price: "10" },
        { instrument: { kind: "cfd", symbol: "CFD1" }, units: "1", price: "10" },
        { instrument: { kind: "somethingnew", symbol: "NEW" }, units: "3", price: "2" }
      ]
    }.to_json

    connection = mock("faraday")
    connection.expects(:get).yields(OpenStruct.new(headers: {}, params: {}))
      .returns(faraday_response(status: 200, body: body))
    provider.stubs(:api_connection).returns(connection)

    positions = provider.get_positions(account_id: "acct-1")

    assert_equal %w[AAPL NEW], positions.map { |p| p.dig("instrument", "symbol") }
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


  # --- Device flow (RFC 8628) ---

  test "start_device_authorization posts the public client id to the discovered endpoint" do
    configure_device_flow_only!

    request = OpenStruct.new(headers: {})
    connection = mock("faraday")
    connection.expects(:get).with(Provider::Snaptrade::OAUTH_DISCOVERY_URL)
      .returns(faraday_response(status: 200, body: discovery_body))
    connection.expects(:post).with("https://api.snaptrade.com/oauth/device_authorization/").yields(request)
      .returns(faraday_response(status: 200, body: {
        device_code: "dev-c0de", user_code: "WXYZ-1234",
        verification_uri: "https://app.snaptrade.com/device",
        verification_uri_complete: "https://app.snaptrade.com/device?code=WXYZ-1234",
        expires_in: 600, interval: 5
      }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    payload = Provider::Snaptrade.start_device_authorization

    assert_equal "dev-c0de", payload["device_code"]
    assert_equal "WXYZ-1234", payload["user_code"]
    body = Rack::Utils.parse_query(request.body)
    assert_equal "client-id", body["client_id"]
    assert_equal "read", body["scope"]
  end

  test "start_device_authorization authenticates a confidential client" do
    configure_oauth!

    request = OpenStruct.new(headers: {})
    connection = mock("faraday")
    connection.expects(:get).returns(faraday_response(status: 200, body: discovery_body))
    connection.expects(:post).yields(request)
      .returns(faraday_response(status: 200, body: {
        device_code: "dev-c0de", user_code: "WXYZ-1234", verification_uri: "https://app.snaptrade.com/device"
      }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    Provider::Snaptrade.start_device_authorization

    assert_equal "Basic #{Base64.strict_encode64('client-id:client-secret')}", request.headers["Authorization"]
    assert_nil Rack::Utils.parse_query(request.body)["client_id"]
  end

  test "start_device_authorization rejects a 2xx that cannot drive the flow" do
    configure_device_flow_only!

    connection = mock("faraday")
    connection.expects(:get).returns(faraday_response(status: 200, body: discovery_body))
    # A device code with nothing to show the user and nowhere to send them
    # would render a blank drawer the user can only abandon.
    connection.expects(:post).returns(faraday_response(status: 200, body: { device_code: "dev-c0de" }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    error = assert_raises(Provider::Snaptrade::ApiError) { Provider::Snaptrade.start_device_authorization }
    assert_match "user_code", error.message
    assert_match "verification_uri", error.message
  end

  test "start_device_authorization accepts verification_uri_complete in place of verification_uri" do
    configure_device_flow_only!

    connection = mock("faraday")
    connection.expects(:get).returns(faraday_response(status: 200, body: discovery_body))
    connection.expects(:post).returns(faraday_response(status: 200, body: {
      device_code: "dev-c0de", user_code: "WXYZ-1234",
      verification_uri_complete: "https://app.snaptrade.com/device?code=WXYZ-1234"
    }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    payload = Provider::Snaptrade.start_device_authorization

    assert_equal "dev-c0de", payload["device_code"]
  end

  test "start_device_authorization raises when the metadata has no device endpoint" do
    configure_device_flow_only!

    connection = mock("faraday")
    connection.expects(:get).returns(faraday_response(status: 200, body: { token_endpoint: Provider::Snaptrade::TOKEN_URL }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    error = assert_raises(Provider::Snaptrade::ApiError) { Provider::Snaptrade.start_device_authorization }
    assert_match "device_authorization_endpoint", error.message
  end

  test "poll_device_token redeems the device code as a public client" do
    configure_device_flow_only!

    request = OpenStruct.new(headers: {})
    connection = mock("faraday")
    connection.expects(:post).with(Provider::Snaptrade::TOKEN_URL).yields(request)
      .returns(faraday_response(status: 200, body: { access_token: "at", refresh_token: "rt", expires_in: 900, token_type: "Bearer", scope: "read" }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    payload = Provider::Snaptrade.poll_device_token(device_code: "dev-c0de")

    assert_equal "at", payload["access_token"]
    # A public client has no secret to authenticate with, so it identifies
    # itself in the body instead of an Authorization header.
    assert_nil request.headers["Authorization"]
    body = Rack::Utils.parse_query(request.body)
    assert_equal Provider::Snaptrade::DEVICE_CODE_GRANT, body["grant_type"]
    assert_equal "dev-c0de", body["device_code"]
    assert_equal "client-id", body["client_id"]
  end

  test "poll_device_token surfaces authorization_pending as a distinguishable error" do
    configure_device_flow_only!

    connection = mock("faraday")
    connection.expects(:post).returns(faraday_response(status: 400, body: { error: "authorization_pending" }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    error = assert_raises(Provider::Snaptrade::AuthenticationError) do
      Provider::Snaptrade.poll_device_token(device_code: "dev-c0de")
    end
    assert_equal "authorization_pending", error.oauth_error
  end

  test "poll_device_token requires a device code" do
    configure_device_flow_only!

    assert_raises(ArgumentError) { Provider::Snaptrade.poll_device_token(device_code: "") }
  end

  # Refresh and revocation are shared by both grants, so they have to work for a
  # deployment that only ever configured the public client id -- otherwise a
  # device-authorized item would authorize fine and then fail at its first
  # token rotation.
  test "refresh_tokens authenticates a public client in the body and a confidential one with basic auth" do
    configure_device_flow_only!

    public_request = OpenStruct.new(headers: {})
    public_connection = mock("faraday")
    public_connection.expects(:post).yields(public_request)
      .returns(faraday_response(status: 200, body: { access_token: "at" }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(public_connection)

    Provider::Snaptrade.refresh_tokens(refresh_token: "rt")

    assert_nil public_request.headers["Authorization"]
    assert_equal "client-id", Rack::Utils.parse_query(public_request.body)["client_id"]

    configure_oauth!

    confidential_request = OpenStruct.new(headers: {})
    confidential_connection = mock("faraday")
    confidential_connection.expects(:post).yields(confidential_request)
      .returns(faraday_response(status: 200, body: { access_token: "at" }.to_json))
    Provider::Snaptrade.stubs(:oauth_connection).returns(confidential_connection)

    Provider::Snaptrade.refresh_tokens(refresh_token: "rt")

    assert_equal "Basic #{Base64.strict_encode64('client-id:client-secret')}", confidential_request.headers["Authorization"]
    assert_nil Rack::Utils.parse_query(confidential_request.body)["client_id"]
  end

  test "revoke_token works for a public client" do
    configure_device_flow_only!

    request = OpenStruct.new(headers: {})
    connection = mock("faraday")
    connection.expects(:post).with(Provider::Snaptrade::REVOKE_URL).yields(request)
      .returns(faraday_response(status: 200, body: ""))
    Provider::Snaptrade.stubs(:oauth_connection).returns(connection)

    assert Provider::Snaptrade.revoke_token(token: "rt")
    assert_nil request.headers["Authorization"]
    body = Rack::Utils.parse_query(request.body)
    assert_equal "rt", body["token"]
    assert_equal "client-id", body["client_id"]
  end
end
