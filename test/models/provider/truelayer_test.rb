require "test_helper"

class Provider::TruelayerTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Truelayer.new("test_token", psu_ip: "1.2.3.4")
  end

  test "raises ConsentExpiredError on 400 invalid_grant" do
    response = stub(code: 400, body: '{"error":"invalid_grant"}')
    assert_raises(Provider::Auth::ConsentExpiredError) do
      @client.send(:handle_response, response)
    end
  end

  test "raises generic Error on other 400s" do
    response = stub(code: 400, body: '{"error":"invalid_request","error_description":"Missing param"}')
    err = assert_raises(Provider::Truelayer::Error) { @client.send(:handle_response, response) }
    assert_match "Missing param", err.message
  end

  test "raises ReauthRequiredError on 401" do
    response = stub(code: 401, body: "{}")
    assert_raises(Provider::Auth::ReauthRequiredError) do
      @client.send(:handle_response, response)
    end
  end

  test "raises ReauthRequiredError on 403" do
    response = stub(code: 403, body: "{}")
    assert_raises(Provider::Auth::ReauthRequiredError) do
      @client.send(:handle_response, response)
    end
  end

  test "includes X-PSU-IP header when psu_ip set" do
    headers = @client.send(:request_headers)
    assert_equal "1.2.3.4", headers["X-PSU-IP"]
  end

  test "omits X-PSU-IP when not set" do
    client = Provider::Truelayer.new("tok")
    assert_not client.send(:request_headers).key?("X-PSU-IP")
  end

  test "uses sandbox API base when sandbox: true" do
    client = Provider::Truelayer.new("tok", sandbox: true)
    assert_equal Provider::Truelayer::SANDBOX_API, client.send(:api_base)
  end

  test "uses production API base by default" do
    assert_equal Provider::Truelayer::PRODUCTION_API, @client.send(:api_base)
  end

  test "rate limit retry re-raises after MAX_RETRIES exhausted" do
    rate_limit = Provider::Truelayer::RateLimitError.new(retry_after: 0)
    calls = 0
    assert_raises(Provider::Truelayer::RateLimitError) do
      @client.send(:with_rate_limit_retry) do
        calls += 1
        raise rate_limit
      end
    end
    assert_equal Provider::Truelayer::MAX_RETRIES + 1, calls
  end

  test "rate limit retry succeeds when block recovers within MAX_RETRIES" do
    rate_limit = Provider::Truelayer::RateLimitError.new(retry_after: 0)
    calls = 0
    result = @client.send(:with_rate_limit_retry) do
      calls += 1
      raise rate_limit if calls < 2
      "ok"
    end
    assert_equal "ok", result
    assert_equal 2, calls
  end

  # TokenClient — OAuth2 token exchange and refresh
  class TokenClientTest < ActiveSupport::TestCase
    setup do
      @token_client = Provider::Truelayer.token_client(
        { client_id: "cid", client_secret: "csecret" }
      )
    end

    test "exchange returns TokenResponse on 200" do
      stub_response = stub(
        code: 200,
        body: '{"access_token":"at","refresh_token":"rt","expires_in":3600}'
      )
      Provider::Truelayer.stubs(:post).returns(stub_response)
      result = @token_client.exchange(code: "code", redirect_uri: "https://example.com/cb")
      assert_equal "at", result.access_token
      assert_equal "rt", result.refresh_token
      assert_equal 3600, result.expires_in
    end

    test "refresh raises ConsentExpiredError on invalid_grant" do
      stub_response = stub(code: 400, body: '{"error":"invalid_grant"}')
      Provider::Truelayer.stubs(:post).returns(stub_response)
      assert_raises(Provider::Auth::ConsentExpiredError) do
        @token_client.refresh("old_refresh_token")
      end
    end

    test "refresh raises Error on other token errors" do
      stub_response = stub(code: 400, body: '{"error":"invalid_client","error_description":"Bad client"}')
      Provider::Truelayer.stubs(:post).returns(stub_response)
      err = assert_raises(Provider::Truelayer::Error) { @token_client.refresh("rt") }
      assert_match "Bad client", err.message
    end

    test "sandbox token client posts to sandbox auth endpoint" do
      sandbox_client = Provider::Truelayer.token_client(
        { client_id: "cid", client_secret: "csecret" }, sandbox: true
      )
      stub_response = stub(code: 200, body: '{"access_token":"at","refresh_token":"rt","expires_in":3600}')
      Provider::Truelayer.expects(:post)
        .with("#{Provider::Truelayer::SANDBOX_AUTH}/connect/token", anything)
        .returns(stub_response)
      sandbox_client.exchange(code: "code", redirect_uri: "https://example.com/cb")
    end
  end
end
