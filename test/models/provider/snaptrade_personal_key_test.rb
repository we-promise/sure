require "test_helper"

# SnapTrade Personal API key mode: requests are signed with the family's own
# consumer key (https://docs.snaptrade.com/docs/request-signatures) and carry
# no userId/userSecret (https://docs.snaptrade.com/docs/authentication-methods).
class Provider::SnaptradePersonalKeyTest < ActiveSupport::TestCase
  CLIENT_ID = "PERSONAL-CLIENT".freeze
  CONSUMER_KEY = "personal-consumer-key".freeze
  TIMESTAMP = 1_715_123_456

  setup do
    @item = families(:dylan_family).snaptrade_items.create!(
      name: "SnapTrade Personal",
      client_id: CLIENT_ID,
      consumer_key: CONSUMER_KEY,
      oauth_token_type: SnaptradeItem::PERSONAL_KEY_TOKEN_TYPE
    )
    @provider = Provider::Snaptrade.new(@item)
  end

  test "data calls are signed with the consumer key, without a bearer token or user credentials" do
    Provider::Snaptrade.expects(:refresh_tokens).never
    stub_request(:get, %r{\Ahttps://api\.snaptrade\.com/api/v1/accounts\?})
      .to_return { |request| @request = request; { status: 200, body: [ { id: "acc-1" } ].to_json } }

    travel_to Time.zone.at(TIMESTAMP) do
      assert_equal [ { "id" => "acc-1" } ], @provider.list_accounts
    end

    assert_nil @request.headers["Authorization"]
    assert_equal "clientId=#{CLIENT_ID}&timestamp=#{TIMESTAMP}", @request.uri.query
    assert_not_includes @request.uri.query, "userId"
    assert_not_includes @request.uri.query, "userSecret"
    assert_equal expected_signature(@request), @request.headers["Signature"]
  end

  test "the signature covers query params exactly as sent" do
    stub_request(:get, %r{\Ahttps://api\.snaptrade\.com/api/v1/accounts/acc-1/activities\?})
      .to_return { |request| @request = request; { status: 200, body: { data: [] }.to_json } }

    travel_to Time.zone.at(TIMESTAMP) do
      @provider.get_account_activities(account_id: "acc-1", start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 12, 31))
    end

    assert_equal "clientId=#{CLIENT_ID}&endDate=2024-12-31&limit=1000&offset=0&startDate=2024-01-01&timestamp=#{TIMESTAMP}",
                 @request.uri.query
    assert_equal expected_signature(@request), @request.headers["Signature"]
  end

  # A known vector, built by hand from the documented canonical form: keys
  # sorted at every level, no whitespace, and the body URL's "&" left as is.
  test "connection portal login signs and sends the canonical JSON body" do
    redirect = "https://sure.test/snaptrade_items/callback?item_id=1&return_to=setup_accounts"
    canonical_body = %({"connectionType":"read","customRedirect":"#{redirect}"})
    signed = %({"content":#{canonical_body},"path":"/api/v1/snapTrade/login","query":"clientId=#{CLIENT_ID}&timestamp=#{TIMESTAMP}"})
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", CONSUMER_KEY, signed))

    stub = stub_request(:post, "https://api.snaptrade.com/api/v1/snapTrade/login?clientId=#{CLIENT_ID}&timestamp=#{TIMESTAMP}")
      .with(body: canonical_body, headers: { "Signature" => signature, "Content-Type" => "application/json" })
      .to_return(status: 200, body: { redirectURI: "https://app.snaptrade.com/portal" }.to_json)

    url = travel_to(Time.zone.at(TIMESTAMP)) { @provider.get_connection_url(redirect_url: redirect) }

    assert_equal "https://app.snaptrade.com/portal", url
    assert_requested stub
  end

  # SnapTrade documents no timestamp tolerance, and network retries can be
  # minutes apart, so each attempt must be signed afresh.
  test "a retried request is re-signed with a fresh timestamp" do
    @provider.stubs(:sleep)
    stub_request(:get, %r{\Ahttps://api\.snaptrade\.com/api/v1/accounts\?})
      .to_raise(Faraday::ConnectionFailed.new("boom")).then
      .to_return { |request| @request = request; { status: 200, body: "[]" } }
    Time.stubs(:current).returns(Time.zone.at(TIMESTAMP), Time.zone.at(TIMESTAMP + 120))

    @provider.list_accounts

    assert_equal "clientId=#{CLIENT_ID}&timestamp=#{TIMESTAMP + 120}", @request.uri.query
    assert_equal expected_signature(@request), @request.headers["Signature"]
  end

  test "a rejected key marks the item for update instead of refreshing a token" do
    Provider::Snaptrade.expects(:refresh_tokens).never
    stub_request(:get, %r{\Ahttps://api\.snaptrade\.com/api/v1/accounts\?}).to_return(status: 401, body: "{}")

    assert_raises(Provider::Snaptrade::AuthenticationError) { @provider.list_accounts }
    assert @item.reload.requires_update?
  end

  # Personal keys allow 10 requests a minute per account.
  test "a rate-limited key stops further requests from this provider" do
    stub = stub_request(:get, %r{\Ahttps://api\.snaptrade\.com/api/v1/accounts\?}).to_return(status: 429, body: "{}")

    2.times { assert_raises(Provider::Snaptrade::RateLimitError) { @provider.list_accounts } }

    assert_requested stub, times: 1
    assert_instance_of Provider::Snaptrade::RateLimitError, @provider.rate_limit_error
  end

  test "a rate-limited account does not block requests for another account" do
    stub_request(:get, %r{/api/v1/accounts/A/positions}).to_return(status: 429, body: "{}")
    stub_request(:get, %r{/api/v1/accounts/B/positions}).to_return(status: 200, body: { results: [] }.to_json)

    assert_raises(Provider::Snaptrade::RateLimitError) { @provider.get_positions(account_id: "A") }
    assert_equal [], @provider.get_positions(account_id: "B")
  end

  test "OAuth authorization without a token_type clears the Personal key marker" do
    @item.apply_oauth_tokens!("access_token" => "at", "expires_in" => 3600)

    assert_not @item.reload.personal_key_configured?
  end

  test "authorizing with OAuth switches the item back to Bearer requests" do
    @item.apply_oauth_tokens!("access_token" => "at-1", "token_type" => "Bearer", "expires_in" => 3600)
    stub = stub_request(:get, "https://api.snaptrade.com/api/v1/accounts")
      .with(headers: { "Authorization" => "Bearer at-1" })
      .to_return(status: 200, body: "[]")

    Provider::Snaptrade.new(@item).list_accounts

    assert_requested stub
  end

  private

    # Recomputed from what actually went over the wire.
    def expected_signature(request)
      content = request.body.presence && JSON.parse(request.body)
      signed = JSON.generate({ "content" => content, "path" => request.uri.path, "query" => request.uri.query })
      Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", CONSUMER_KEY, signed))
    end
end
