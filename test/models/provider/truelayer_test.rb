require "test_helper"
require "ostruct"

class Provider::TruelayerTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Truelayer.new(client_id: "test-client", client_secret: "secret")
  end

  test "uses live hosts for a live client id and sandbox hosts for a sandbox one" do
    sandbox = Provider::Truelayer.new(client_id: "sandbox-test-client", client_secret: "secret")

    assert_equal "https://api.truelayer.com", @provider.api_base_url
    assert_equal "https://auth.truelayer-sandbox.com", sandbox.auth_base_url
  end

  test "builds a consent URL asking for offline access" do
    uri = URI.parse(@provider.authorization_url(redirect_uri: "http://localhost:3000/truelayer_items/callback", state: "s1"))
    query = Rack::Utils.parse_query(uri.query)

    assert_equal "auth.truelayer.com", uri.host
    assert_equal "test-client", query["client_id"]
    assert_equal "s1", query["state"]
    assert_includes query["scope"].split, "offline_access"
    assert_includes query["scope"].split, "cards"
  end

  test "refreshing returns the rotated tokens" do
    Provider::Truelayer.expects(:post).with do |url, options|
      url == "https://auth.truelayer.com/connect/token" && options[:body].include?("grant_type=refresh_token")
    end.returns(response(200, { access_token: "a", refresh_token: "r2", expires_in: 3600 }.to_json))

    assert_equal({ access_token: "a", refresh_token: "r2", expires_in: 3600 }, @provider.refresh_access_token("r1"))
  end

  test "a dead refresh token raises an invalid_grant error that needs reauthorization" do
    Provider::Truelayer.expects(:post).returns(response(400, { error: "invalid_grant" }.to_json))

    error = assert_raises(Provider::Truelayer::TruelayerError) { @provider.refresh_access_token("r1") }
    assert_equal :invalid_grant, error.error_type
    assert error.reauth_required?
  end

  test "a provider without a cards endpoint is reported as unsupported, not as having no cards" do
    Provider::Truelayer.expects(:get).twice.returns(response(501, ""), response(200, { results: [] }.to_json))

    assert_nil @provider.get_cards("token")
    assert_equal [], @provider.get_cards("token")
  end

  test "the token endpoint is not retried and uses a short timeout, since it is called under a row lock" do
    Provider::Truelayer.expects(:post).once.with { |_url, options| options[:timeout] == Provider::Truelayer::TOKEN_TIMEOUT }.returns(response(503, ""))
    @provider.expects(:sleep).never

    error = assert_raises(Provider::Truelayer::TruelayerError) { @provider.refresh_access_token("r1") }
    assert_equal :server_error, error.error_type
  end

  test "a 403 from the data API means consent lapsed" do
    Provider::Truelayer.expects(:get).returns(response(403, { error: "access_denied" }.to_json))

    error = assert_raises(Provider::Truelayer::TruelayerError) { @provider.get_accounts("token") }
    assert_equal :consent_expired, error.error_type
    assert error.reauth_required?
  end

  test "does not retry a rate limit, which would spend more of the daily quota" do
    Provider::Truelayer.expects(:get).once.returns(response(429, { error: "rate_limit_exceeded" }.to_json))

    error = assert_raises(Provider::Truelayer::TruelayerError) do
      @provider.get_transactions("token", kind: "account", account_id: "a1", from: 1.day.ago, to: Time.current)
    end
    assert_equal :rate_limited, error.error_type
  end

  test "retries a server error" do
    Provider::Truelayer.expects(:get).twice.returns(response(503, ""), response(200, { results: [ { current: 5 } ] }.to_json))
    @provider.expects(:sleep).once

    assert_equal({ current: 5 }, @provider.get_balance("token", kind: "card", account_id: "c1"))
  end

  test "requests card transactions from the cards collection with ISO timestamps" do
    from = Time.utc(2026, 1, 1)
    to = Time.utc(2026, 2, 1)
    Provider::Truelayer.expects(:get).with do |url, options|
      url == "https://api.truelayer.com/data/v1/cards/c%201/transactions?from=2026-01-01T00%3A00%3A00Z&to=2026-02-01T00%3A00%3A00Z" &&
        options[:headers]["Authorization"] == "Bearer token"
    end.returns(response(200, { results: [ { transaction_id: "t" } ] }.to_json))

    assert_equal [ { transaction_id: "t" } ], @provider.get_transactions("token", kind: "card", account_id: "c 1", from: from, to: to)
  end

  test "a 403 sca_exceeded on older history is a refused range, not a lost connection" do
    Provider::Truelayer.expects(:get).returns(response(403, { error: "sca_exceeded", error_description: "SCA exemption has expired." }.to_json))

    error = assert_raises(Provider::Truelayer::TruelayerError) do
      @provider.get_transactions("token", kind: "account", account_id: "a1", from: 3.years.ago, to: 2.years.ago)
    end
    assert error.history_refused?
    assert_not error.reauth_required?
  end

  test "a 400 from the data API is a refused range, while a 400 from the token endpoint still needs reauthorization" do
    Provider::Truelayer.expects(:get).returns(response(400, { error: "validation_error", error_description: "Invalid date range provided." }.to_json))
    range_error = assert_raises(Provider::Truelayer::TruelayerError) { @provider.get_accounts("token") }
    assert range_error.history_refused?
    assert_not range_error.reauth_required?

    Provider::Truelayer.expects(:post).returns(response(400, { error: "invalid_grant" }.to_json))
    grant_error = assert_raises(Provider::Truelayer::TruelayerError) { @provider.refresh_access_token("r1") }
    assert_not grant_error.history_refused?
    assert grant_error.reauth_required?
  end

  private

    def response(code, body, message = "")
      OpenStruct.new(code: code, body: body, message: message)
    end
end
