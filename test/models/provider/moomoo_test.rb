require "test_helper"
require "ostruct"

class Provider::MoomooTest < ActiveSupport::TestCase
  BASE_URL = "https://webapi.moomoo.com".freeze
  CALLBACK_URL = "http://www.example.com/moomoo_items/callback".freeze
  ACCOUNT_PATH = "#{BASE_URL}/api/v1.0/accounts/acc-1".freeze

  setup do
    @provider = Provider::Moomoo.new(client_id: "client-1")
    @provider.stubs(:sleep)
  end

  test "registers a public client for the callback URL, asking for read-only scopes" do
    request = stub_request(:post, "#{BASE_URL}/oauth2/register").with { |req|
      body = JSON.parse(req.body)
      body["redirect_uris"] == [ CALLBACK_URL ] &&
        body["token_endpoint_auth_method"] == "none" &&
        body["grant_types"] == %w[authorization_code refresh_token] &&
        body["response_types"] == %w[code] &&
        body["scope"] == "trade:read accid:*"
    }.to_return(status: 201, body: {
      client_id: "cid",
      registration_access_token: "rat",
      registration_client_uri: "#{BASE_URL}/oauth2/register/cid",
      scope: "trade:read accid:*",
      pkce_required: true
    }.to_json)

    result = Provider::Moomoo.register_client(redirect_uri: CALLBACK_URL)

    assert_requested request
    assert_equal(
      { client_id: "cid", registration_access_token: "rat", registration_client_uri: "#{BASE_URL}/oauth2/register/cid", scope: "trade:read accid:*" },
      result
    )
  end

  test "registers again without a scope whenever moomoo refuses the scoped request" do
    [
      [ 400, { error: "invalid_client_metadata" } ],
      [ 400, { error: "invalid_request", error_description: "unknown parameter scope" } ],
      [ 200, { s: "error", errcode: -1, errmsg: "invalid param: scope" } ],
      [ 403, { s: "error", errcode: -12009, errmsg: "blocked" } ],
      [ 500, {} ]
    ].each do |status, body|
      WebMock.reset!
      stub_request(:post, "#{BASE_URL}/oauth2/register").with { |req| JSON.parse(req.body).key?("scope") }
        .to_return(status: status, body: body.to_json)
      plain = stub_request(:post, "#{BASE_URL}/oauth2/register").with { |req| !JSON.parse(req.body).key?("scope") }
        .to_return(status: 200, body: { client_id: "cid" }.to_json)

      assert_equal "cid", Provider::Moomoo.register_client(redirect_uri: CALLBACK_URL)[:client_id], "#{status} #{body}"
      assert_requested plain, times: 1
    end
  end

  test "a scoped registration that works is not repeated" do
    stub_request(:post, "#{BASE_URL}/oauth2/register").with { |req| JSON.parse(req.body).key?("scope") }
      .to_return(status: 201, body: { client_id: "cid" }.to_json)
    plain = stub_request(:post, "#{BASE_URL}/oauth2/register").with { |req| !JSON.parse(req.body).key?("scope") }

    assert_equal "cid", Provider::Moomoo.register_client(redirect_uri: CALLBACK_URL)[:client_id]
    assert_not_requested plain
  end

  test "a refused registration raises registration_failed with the documented request's reason" do
    stub_request(:post, "#{BASE_URL}/oauth2/register").with { |req| JSON.parse(req.body).key?("scope") }
      .to_return(status: 400, body: { error: "invalid_request", error_description: "unknown parameter scope" }.to_json)
    stub_request(:post, "#{BASE_URL}/oauth2/register").with { |req| !JSON.parse(req.body).key?("scope") }
      .to_return(status: 400, body: { error: "invalid_redirect_uri", error_description: "redirect_uri not allowed" }.to_json)

    refused = assert_raises(Provider::Moomoo::MoomooError) { Provider::Moomoo.register_client(redirect_uri: CALLBACK_URL) }
    assert_equal :registration_failed, refused.error_type
    assert_includes refused.message, "redirect_uri not allowed"
    assert_equal "invalid_redirect_uri", refused.code

    WebMock.reset!
    stub_request(:post, "#{BASE_URL}/oauth2/register").to_return(status: 200, body: { client_name: "Sure" }.to_json)
    no_client = assert_raises(Provider::Moomoo::MoomooError) { Provider::Moomoo.register_client(redirect_uri: CALLBACK_URL) }
    assert_equal :registration_failed, no_client.error_type
  end

  test "the PKCE challenge is the S256 hash of the verifier" do
    pkce = Provider::Moomoo.generate_pkce

    assert_includes 43..128, pkce[:verifier].length
    assert_equal Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(pkce[:verifier]), padding: false), pkce[:challenge]
  end

  test "the authorization URL is moomoo's consent page with PKCE and no scope" do
    uri = URI.parse(@provider.authorization_url(redirect_uri: CALLBACK_URL, state: "s1", code_challenge: "challenge"))

    assert_equal "https", uri.scheme
    assert_equal "webapi.moomoo.com", uri.host
    assert_equal "/oauth2/authorize/confirm", uri.path
    assert_equal(
      {
        "client_id" => "client-1",
        "code_challenge" => "challenge",
        "code_challenge_method" => "S256",
        "redirect_uri" => CALLBACK_URL,
        "response_type" => "code",
        "state" => "s1"
      },
      Rack::Utils.parse_query(uri.query)
    )
  end

  test "exchanges the code once, form-encoded and with a short timeout" do
    Provider::Moomoo.expects(:post).once.with { |url, options|
      url == "#{BASE_URL}/oauth2/token" &&
        options[:timeout] == Provider::Moomoo::TOKEN_TIMEOUT &&
        options[:headers]["Content-Type"] == "application/x-www-form-urlencoded" &&
        Rack::Utils.parse_query(options[:body]) == {
          "grant_type" => "authorization_code", "code" => "c1", "client_id" => "client-1",
          "redirect_uri" => CALLBACK_URL, "code_verifier" => "v1"
        }
    }.returns(response(200, { access_token: "at", token_type: "Bearer", expires_in: 7200, refresh_token: "rt", scope: "trade:read accid:1" }.to_json))

    assert_equal(
      { access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "trade:read accid:1" },
      @provider.exchange_code(code: "c1", redirect_uri: CALLBACK_URL, code_verifier: "v1")
    )
  end

  test "a refresh returns no refresh token, since moomoo keeps the original" do
    Provider::Moomoo.expects(:post).with { |_url, options|
      Rack::Utils.parse_query(options[:body]) == { "grant_type" => "refresh_token", "refresh_token" => "r1", "client_id" => "client-1" }
    }.returns(response(200, { access_token: "new", token_type: "Bearer", expires_in: 7200, scope: "trade:read accid:1" }.to_json))

    tokens = @provider.refresh_access_token("r1")

    assert_equal "new", tokens[:access_token]
    assert_nil tokens[:refresh_token]
  end

  test "token endpoint errors tell a dead connection from a transient failure" do
    Provider::Moomoo.stubs(:post).returns(
      response(400, { error: "invalid_grant" }.to_json),
      response(401, { error: "invalid_client" }.to_json),
      response(503, ""),
      response(400, "")
    )

    dead = assert_raises(Provider::Moomoo::MoomooError) { @provider.refresh_access_token("r1") }
    assert_equal :invalid_grant, dead.error_type
    assert dead.reauth_required?

    unknown_client = assert_raises(Provider::Moomoo::MoomooError) { @provider.refresh_access_token("r1") }
    assert_equal :invalid_client, unknown_client.error_type
    assert unknown_client.reauth_required?

    unavailable = assert_raises(Provider::Moomoo::MoomooError) { @provider.refresh_access_token("r1") }
    assert_equal :token_failed, unavailable.error_type
    assert_not unavailable.reauth_required?

    bare = assert_raises(Provider::Moomoo::MoomooError) { @provider.refresh_access_token("r1") }
    assert_equal :invalid_grant, bare.error_type
  end

  test "a network failure on the token endpoint is transient and not retried" do
    Provider::Moomoo.expects(:post).once.raises(Net::OpenTimeout)

    error = assert_raises(Provider::Moomoo::MoomooError) { @provider.refresh_access_token("r1") }
    assert_equal :token_failed, error.error_type
    assert_not error.reauth_required?
  end

  test "envelope error codes map to error types" do
    {
      -12102 => :token_expired,
      -12006 => :unauthorized,
      -12009 => :scope_missing
    }.each do |errcode, error_type|
      stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(status: 200, body: { s: "error", errcode: errcode, errmsg: "nope" }.to_json)

      error = assert_raises(Provider::Moomoo::MoomooError) { @provider.get_positions("token", acc_id: "acc-1") }
      assert_equal error_type, error.error_type
      assert_equal errcode, error.code
    end

    assert Provider::Moomoo::MoomooError.new("x", :scope_missing).reauth_required?
    assert Provider::Moomoo::MoomooError.new("x", :token_expired).retry_with_fresh_token?
  end

  test "a request timeout is retried twice before giving up" do
    request = stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(status: 200, body: { s: "error", errcode: -12301 }.to_json)

    error = assert_raises(Provider::Moomoo::MoomooError) { @provider.get_positions("token", acc_id: "acc-1") }
    assert_equal :timeout, error.error_type
    assert_requested request, times: 3
  end

  test "responses without a moomoo envelope are classified by HTTP status" do
    stub_request(:get, "#{ACCOUNT_PATH}/positions")
      .to_return({ status: 401, body: "" }, { status: 200, body: { d: [] }.to_json }, { status: 403, body: "<html>blocked</html>" })

    assert_equal :token_expired, assert_raises(Provider::Moomoo::MoomooError) { @provider.get_positions("token", acc_id: "acc-1") }.error_type
    assert_equal :api_error, assert_raises(Provider::Moomoo::MoomooError) { @provider.get_positions("token", acc_id: "acc-1") }.error_type
    assert_equal :api_error, assert_raises(Provider::Moomoo::MoomooError) { @provider.get_positions("token", acc_id: "acc-1") }.error_type
  end

  test "a rate limit waits for Retry-After, or backs off without one" do
    stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(
      { status: 429, headers: { "Retry-After" => "3" }, body: "" },
      { status: 200, body: { s: "error", errcode: -12011 }.to_json },
      { status: 200, body: { s: "ok", d: [] }.to_json }
    )
    @provider.expects(:sleep).with(3).once
    @provider.expects(:sleep).with(4).once

    assert_equal [], @provider.get_positions("token", acc_id: "acc-1")
  end

  test "a rate limit that outlasts the retries raises rate_limited" do
    request = stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(status: 429, body: "")

    error = assert_raises(Provider::Moomoo::MoomooError) { @provider.get_positions("token", acc_id: "acc-1") }
    assert_equal :rate_limited, error.error_type
    assert_not error.reauth_required?
    assert_requested request, times: Provider::Moomoo::MAX_RATE_LIMIT_RETRIES + 1
  end

  test "positions are a bare array and account ids keep every digit" do
    stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(status: 200, body: { s: "ok", d: [ { code: "US.AAPL" } ] }.to_json)
    stub_request(:get, "#{BASE_URL}/api/v1.0/accounts/authorized_trd_accs")
      .with(headers: { "Authorization" => "Bearer token" })
      .to_return(status: 200, body: '{"s":"ok","d":{"accounts":[{"account_id":987654321098765432,"security_firm":"FUTUSG"}]}}')

    assert_equal [ { "code" => "US.AAPL" } ], @provider.get_positions("token", acc_id: "acc-1")
    assert_equal "987654321098765432", @provider.get_accounts("token").first["account_id"].to_s
  end

  test "funds always ask for the account currency" do
    request = stub_request(:get, "#{ACCOUNT_PATH}/funds").with(query: { currency: "SGD" })
      .to_return(status: 200, body: { s: "ok", d: { currency: "SGD", total_assets: "100.00" } }.to_json)

    assert_equal "100.00", @provider.get_funds("token", acc_id: "acc-1", currency: "SGD")["total_assets"]
    assert_requested request
  end

  test "fills history pages on page_flag with microsecond bounds" do
    start_us = Provider::Moomoo.to_micros(Time.utc(2026, 7, 27))
    end_us = Provider::Moomoo.to_micros(Time.utc(2026, 10, 24))
    base_query = { trd_market: "US", start: start_us.to_s, end: end_us.to_s, page_size: "50" }

    first = stub_request(:get, "#{ACCOUNT_PATH}/fills_history").with(query: base_query.merge(page_flag: ""))
      .to_return(status: 200, body: { s: "ok", d: { order_fills: [ { deal_id: "a" } ], page_flag: "next", completed: false } }.to_json)
    second = stub_request(:get, "#{ACCOUNT_PATH}/fills_history").with(query: base_query.merge(page_flag: "next"))
      .to_return(status: 200, body: { s: "ok", d: { order_fills: [ { deal_id: "b" } ], page_flag: "", completed: true } }.to_json)

    result = @provider.get_fills_history("token", acc_id: "acc-1", trd_market: "US", start_us: start_us, end_us: end_us)

    assert_equal 16, start_us.to_s.length
    assert_equal %w[a b], result[:records].map { |fill| fill["deal_id"] }
    assert_not result[:truncated]
    assert_requested first
    assert_requested second
  end

  test "cash logs leave page_flag out of the first request" do
    first = stub_request(:get, "#{ACCOUNT_PATH}/cash_logs").with(query: { begin_time: "1", end_time: "2", page_size: "20" })
      .to_return(status: 200, body: { s: "ok", d: { cash_logs: [ { cash_change: "1" } ], page_flag: "p2", completed: false } }.to_json)
    second = stub_request(:get, "#{ACCOUNT_PATH}/cash_logs").with(query: { begin_time: "1", end_time: "2", page_size: "20", page_flag: "p2" })
      .to_return(status: 200, body: { s: "ok", d: { cash_logs: [ { cash_change: "2" } ], page_flag: "p3", completed: true } }.to_json)

    result = @provider.get_cash_logs("token", acc_id: "acc-1", begin_us: 1, end_us: 2)

    assert_equal 2, result[:records].size
    assert_requested first
    assert_requested second
  end

  test "an empty page does not end paging while moomoo says more follows" do
    stub_request(:get, "#{ACCOUNT_PATH}/fills_history").with(query: hash_including(page_flag: ""))
      .to_return(status: 200, body: { s: "ok", d: { order_fills: [ { deal_id: "a" } ], page_flag: "p2", completed: false } }.to_json)
    stub_request(:get, "#{ACCOUNT_PATH}/fills_history").with(query: hash_including(page_flag: "p2"))
      .to_return(status: 200, body: { s: "ok", d: { order_fills: [], page_flag: "p3", completed: false } }.to_json)
    last = stub_request(:get, "#{ACCOUNT_PATH}/fills_history").with(query: hash_including(page_flag: "p3"))
      .to_return(status: 200, body: { s: "ok", d: { order_fills: [ { deal_id: "c" } ], page_flag: "", completed: true } }.to_json)

    result = @provider.get_fills_history("token", acc_id: "acc-1", trd_market: "US", start_us: 1, end_us: 2)

    assert_equal %w[a c], result[:records].map { |fill| fill["deal_id"] }
    assert_not result[:truncated]
    assert_requested last
  end

  test "a blank page_flag ends paging" do
    request = stub_request(:get, "#{ACCOUNT_PATH}/fills_history").with(query: hash_including(trd_market: "US"))
      .to_return(status: 200, body: { s: "ok", d: { order_fills: [ { deal_id: "a" } ], page_flag: "", completed: false } }.to_json)

    result = @provider.get_fills_history("token", acc_id: "acc-1", trd_market: "US", start_us: 1, end_us: 2)

    assert_equal %w[a], result[:records].map { |fill| fill["deal_id"] }
    assert_not result[:truncated]
    assert_requested request, times: 1
  end

  test "paging stops short on a repeated page_flag and after the page limit" do
    stub_request(:get, "#{ACCOUNT_PATH}/order_fills").with(query: hash_including(trd_market: "HK"))
      .to_return(status: 200, body: { s: "ok", d: { order_fills: [ { deal_id: "x" } ], page_flag: "same", completed: false } }.to_json)

    repeated = @provider.get_today_fills("token", acc_id: "acc-1", trd_market: "HK")
    assert_equal 2, repeated[:records].size
    assert repeated[:truncated]
    assert_equal :repeated_page_flag, repeated[:reason]

    stub_request(:get, "#{ACCOUNT_PATH}/order_fills").with(query: hash_including(trd_market: "US")).to_return do |request|
      page = Rack::Utils.parse_query(URI(request.uri).query)["page_flag"].to_i
      { status: 200, body: { s: "ok", d: { order_fills: [ { deal_id: page.to_s } ], page_flag: (page + 1).to_s, completed: false } }.to_json }
    end

    endless = @provider.get_today_fills("token", acc_id: "acc-1", trd_market: "US")
    assert endless[:truncated]
    assert_equal :page_limit, endless[:reason]
    assert_equal Provider::Moomoo::MAX_PAGES_PER_WINDOW, endless[:records].size
  end

  test "a positions answer without a position list is an error, and no positions at all is empty" do
    stub_request(:get, "#{ACCOUNT_PATH}/positions")
      .to_return({ status: 200, body: { s: "ok", d: { unexpected: 1 } }.to_json }, { status: 200, body: { s: "ok", d: nil }.to_json })

    error = assert_raises(Provider::Moomoo::MoomooError) { @provider.get_positions("token", acc_id: "acc-1") }
    assert_equal :api_error, error.error_type
    assert_equal [], @provider.get_positions("token", acc_id: "acc-1")
  end

  test "every attempt counts against the request budget" do
    provider = Provider::Moomoo.new(client_id: "client-1", budget: Provider::Moomoo::RequestBudget.new(2))
    provider.stubs(:sleep)
    stub_request(:get, "#{ACCOUNT_PATH}/positions")
      .to_return({ status: 503, body: "" }, { status: 200, body: { s: "ok", d: [] }.to_json })

    assert_equal [], provider.get_positions("token", acc_id: "acc-1")

    error = assert_raises(Provider::Moomoo::MoomooError) { provider.get_positions("token", acc_id: "acc-1") }
    assert_equal :budget_exhausted, error.error_type
    assert_not error.reauth_required?
  end

  test "requests within a sync are spaced apart" do
    stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(status: 200, body: { s: "ok", d: [] }.to_json)
    @provider.stubs(:monotonic_now).returns(100.0, 100.2)
    @provider.expects(:sleep).with { |seconds| (seconds - (Provider::Moomoo::MIN_REQUEST_INTERVAL - 0.2)).abs < 1e-9 }.once

    2.times { @provider.get_positions("token", acc_id: "acc-1") }
  end

  # Every sync on the deployment shares moomoo's per-IP limit, so the count
  # lives in the cache rather than in one client.
  test "a request over the deployment's per-minute count waits for the next minute" do
    stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(status: 200, body: { s: "ok", d: [] }.to_json)
    travel_to Time.zone.parse("2026-11-05 10:00:45 UTC") do
      Rails.cache.expects(:increment).twice.returns(Provider::Moomoo::MAX_REQUESTS_PER_MINUTE + 1, 1)
      @provider.expects(:sleep).with(16).once

      @provider.get_positions("token", acc_id: "acc-1")
    end
  end

  test "a request within the deployment's per-minute count goes straight out" do
    stub_request(:get, "#{ACCOUNT_PATH}/positions").to_return(status: 200, body: { s: "ok", d: [] }.to_json)
    Rails.cache.expects(:increment).with(regexp_matches(/\Amoomoo:requests:\d+\z/), 1, expires_in: 2.minutes).once.returns(Provider::Moomoo::MAX_REQUESTS_PER_MINUTE)
    @provider.expects(:sleep).never

    @provider.get_positions("token", acc_id: "acc-1")
  end

  test "trading timestamps are microseconds" do
    time = Time.zone.parse("2024-03-01 00:00:00 UTC")

    assert_equal 1709251200000000, Provider::Moomoo.to_micros(time)
    assert_equal time, Provider::Moomoo.from_micros(1709251200000000)
    assert_equal time, Provider::Moomoo.from_micros("1709251200000000")
    assert_nil Provider::Moomoo.from_micros(nil)
    assert_nil Provider::Moomoo.from_micros(0)
  end

  test "a connection without a registered client cannot build a client" do
    error = assert_raises(Provider::Moomoo::MoomooError) { Provider::Moomoo.new(client_id: nil) }
    assert_equal :not_connected, error.error_type
  end

  private

    def response(code, body, headers: {})
      OpenStruct.new(code: code, body: body, headers: headers)
    end
end
