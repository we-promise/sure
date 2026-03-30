require "test_helper"

class Provider::BinanceTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Binance.new(api_key: "test_key", api_secret: "test_secret")
  end

  test "sign produces HMAC-SHA256 hex digest" do
    params = { "timestamp" => "1000", "recvWindow" => "5000" }
    sig = @provider.send(:sign, params)
    expected = OpenSSL::HMAC.hexdigest("sha256", "test_secret", "timestamp=1000&recvWindow=5000")
    assert_equal expected, sig
  end

  test "auth_headers include X-MBX-APIKEY" do
    headers = @provider.send(:auth_headers)
    assert_equal "test_key", headers["X-MBX-APIKEY"]
  end

  test "timestamp_params returns hash with timestamp" do
    params = @provider.send(:timestamp_params)
    assert params["timestamp"].present?
    assert_in_delta Time.now.to_i * 1000, params["timestamp"].to_i, 5000
  end

  test "handle_response raises AuthenticationError on 401" do
    response = mock_httparty_response(401, { "msg" => "Invalid API-key" })
    assert_raises(Provider::Binance::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises RateLimitError on 429" do
    response = mock_httparty_response(429, {})
    assert_raises(Provider::Binance::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises ApiError on other non-2xx" do
    response = mock_httparty_response(403, { "msg" => "WAF Limit" })
    assert_raises(Provider::Binance::ApiError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response returns parsed body on 200" do
    response = mock_httparty_response(200, { "balances" => [] })
    result = @provider.send(:handle_response, response)
    assert_equal({ "balances" => [] }, result)
  end

  private

    def mock_httparty_response(code, body)
      response = mock
      response.stubs(:code).returns(code)
      response.stubs(:parsed_response).returns(body)
      response
    end
end
