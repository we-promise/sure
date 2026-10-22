require "test_helper"

class Provider::SaxoTest < ActiveSupport::TestCase
  setup do
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"
    @item = mock("Saxo item")
    @provider = Provider::Saxo.new(@item)
  end

  test "pagination retains account filters and never follows an external URL" do
    @item.stubs(:access_token!).returns("test-access")
    stub_request(:get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me")
      .with(query: { "$skip" => "0", "$top" => "100" })
      .to_return(body: { Data: [ { AccountId: "one" } ], __next: "https://attacker.example/openapi/port/v1/accounts/me?$skip=1" }.to_json)
    assert_raises(Provider::Saxo::Error) { @provider.accounts }
    assert_not_requested(:get, /attacker/)
  end

  test "all pages are collected" do
    @item.stubs(:access_token!).returns("test-access")
    stub_request(:get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me")
      .with(query: { "$skip" => "0", "$top" => "100" })
      .to_return(body: { Data: [ { AccountId: "one" } ], __next: "/openapi/port/v1/accounts/me?$skip=1" }.to_json)
    stub_request(:get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me")
      .with(query: { "$skip" => "1", "$top" => "100" })
      .to_return(body: { Data: [ { AccountId: "two" } ] }.to_json)
    assert_equal %w[one two], @provider.accounts.map { |row| row["AccountId"] }
  end

  test "unauthorized requests renew exactly once" do
    @item.expects(:access_token!).with(force_refresh: false).returns("old")
    @item.expects(:access_token!).with(force_refresh: true, rejected_token: "old").returns("new")
    stub_request(:get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me")
      .with(query: { "$skip" => "0", "$top" => "100" }).to_return(status: 401).then.to_return(body: { Data: [] }.to_json)
    assert_empty @provider.accounts
  end

  test "rate limiting retries with the session reset and keeps the current token" do
    @item.expects(:access_token!).with(force_refresh: false).twice.returns("test-access")
    @provider.expects(:sleep).with(3).once
    stub_request(:get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me")
      .with(query: { "$skip" => "0", "$top" => "100" })
      .to_return(status: 429, headers: { "X-RateLimit-Session-Remaining" => "0", "X-RateLimit-Session-Reset" => "3" })
      .then.to_return(status: 200, body: { Data: [] }.to_json)

    assert_empty @provider.accounts
  end

  test "rate limiting with a long reset fails without sleeping" do
    @item.stubs(:access_token!).returns("test-access")
    @provider.expects(:sleep).never
    stub_request(:get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me")
      .with(query: { "$skip" => "0", "$top" => "100" })
      .to_return(status: 429, headers: { "X-RateLimit-AppDay-Remaining" => "0", "X-RateLimit-AppDay-Reset" => "600" })

    error = assert_raises(Provider::Saxo::Error) { @provider.accounts }
    assert_equal({ stage: "request", reason: "rate_limited", retry_after_seconds: 600 }, error.diagnostic)
  end

  test "rate limiting retries are bounded when no reset header is provided" do
    @item.stubs(:access_token!).returns("test-access")
    @provider.expects(:sleep).with(2).once
    @provider.expects(:sleep).with(4).once
    stub_request(:get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me")
      .with(query: { "$skip" => "0", "$top" => "100" }).to_return(status: 429)

    assert_raises(Provider::Saxo::Error) { @provider.accounts }
    assert_requested :get, "#{Provider::Saxo::API_URL}/port/v1/accounts/me",
      query: { "$skip" => "0", "$top" => "100" }, times: 3
  end

  test "temporary authorization failures do not require reconnecting" do
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: 503)
    error = assert_raises(Provider::Saxo::Error) { Provider::Saxo.exchange(grant_type: "refresh_token") }
    assert_not_kind_of Provider::Saxo::AuthenticationError, error
  end

  test "OAuth accepts successful token responses for authorization and refresh" do
    [ [ 200, "authorization_code" ], [ 201, "authorization_code" ], [ 201, "refresh_token" ] ].each do |status, grant_type|
      stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: status, body: {
        access_token: "access", refresh_token: "refresh", expires_in: 1200, refresh_token_expires_in: 2400
      }.to_json)

      freeze_time do
        result = Provider::Saxo.exchange(grant_type: grant_type)
        assert_equal "access", result[:access_token]
        assert_equal "refresh", result[:refresh_token]
        assert_equal 20.minutes.from_now, result[:access_expires_at]
        assert_equal 40.minutes.from_now, result[:refresh_expires_at]
      end
    end
  end

  test "OAuth rejects incomplete 201 responses" do
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: 201, body: { access_token: "access" }.to_json)
    error = assert_raises(Provider::Saxo::AuthenticationError) { Provider::Saxo.exchange(grant_type: "authorization_code") }
    assert_equal "missing_fields", error.diagnostic[:reason]
  end

  test "OAuth validates complete rotating tokens and never exposes a failed response" do
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: 400,
      body: { error: "invalid_client", error_description: "secret-token" }.to_json)
    error = assert_raises(Provider::Saxo::AuthenticationError) { Provider::Saxo.exchange(grant_type: "refresh_token") }
    assert_no_match "secret-token", error.message
    assert_equal({ stage: "token_exchange", reason: "http_error", http_status: 400, oauth_error: "invalid_client" }, error.diagnostic)
    assert_no_match "secret-token", error.diagnostic.inspect
  end

  test "OAuth reports missing token response fields without exposing values" do
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: 200,
      body: { access_token: "secret-token", expires_in: 1200, refresh_token: "other-secret" }.to_json)
    error = assert_raises(Provider::Saxo::AuthenticationError) { Provider::Saxo.exchange(grant_type: "authorization_code") }
    assert_equal({ stage: "token_exchange", reason: "missing_fields", missing_fields: [ "refresh_token_expires_in" ] }, error.diagnostic)
    assert_no_match(/secret-token|other-secret/, error.diagnostic.inspect)
  end

  test "OAuth ignores unrecognized error values in diagnostics" do
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: 400,
      body: { error: "secret-token" }.to_json)
    error = assert_raises(Provider::Saxo::AuthenticationError) { Provider::Saxo.exchange(grant_type: "authorization_code") }
    assert_equal({ stage: "token_exchange", reason: "http_error", http_status: 400 }, error.diagnostic)
  end
end
