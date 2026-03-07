require "test_helper"

class Provider::TwelveDataTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::TwelveData.new("test_api_key")
  end

  # ================================
  #    Rate Limit Error Tests
  # ================================

  test "raises RateLimitError on 429 response" do
    # Mock a 429 rate limit response from the API
    error_body = JSON.generate({
      "code" => 429,
      "message" => "You have run out of API credits for the current minute. 27 API credits were used, with the current limit being 8.",
      "status" => "error"
    })

    faraday_error = Faraday::ClientError.new("the server responded with status 429")
    faraday_error.instance_variable_set(:@response, {
      status: 429,
      body: error_body
    })

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(faraday_error)

    response = @provider.fetch_security_prices(
      symbol: "AAPL",
      exchange_operating_mic: "XNAS",
      start_date: Date.parse("2024-01-01"),
      end_date: Date.parse("2024-01-10")
    )

    assert_not response.success?
    assert_instance_of Provider::TwelveData::RateLimitError, response.error
    assert_match(/rate limit exceeded/i, response.error.message)
  end

  test "raises RateLimitError for exchange rates on 429 response" do
    # Mock a 429 rate limit response
    error_body = JSON.generate({
      "code" => 429,
      "message" => "Rate limit exceeded",
      "status" => "error"
    })

    faraday_error = Faraday::ClientError.new("the server responded with status 429")
    faraday_error.instance_variable_set(:@response, {
      status: 429,
      body: error_body
    })

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(faraday_error)

    response = @provider.fetch_exchange_rates(
      from: "USD",
      to: "EUR",
      start_date: Date.parse("2024-01-01"),
      end_date: Date.parse("2024-01-10")
    )

    assert_not response.success?
    assert_instance_of Provider::TwelveData::RateLimitError, response.error
  end

  test "handles non-rate-limit errors normally" do
    # Mock a 500 server error
    error_body = JSON.generate({
      "code" => 500,
      "message" => "Internal server error",
      "status" => "error"
    })

    faraday_error = Faraday::ServerError.new("the server responded with status 500")
    faraday_error.instance_variable_set(:@response, {
      status: 500,
      body: error_body
    })

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(faraday_error)

    response = @provider.fetch_security_prices(
      symbol: "AAPL",
      exchange_operating_mic: "XNAS",
      start_date: Date.parse("2024-01-01"),
      end_date: Date.parse("2024-01-10")
    )

    assert_not response.success?
    # Should be a regular error, not a RateLimitError
    assert_instance_of Provider::TwelveData::Error, response.error
    assert_not_instance_of Provider::TwelveData::RateLimitError, response.error
  end

  test "extracts error message from JSON response body" do
    error_body = JSON.generate({
      "code" => 429,
      "message" => "Custom rate limit message",
      "status" => "error"
    })

    faraday_error = Faraday::ClientError.new("the server responded with status 429")
    faraday_error.instance_variable_set(:@response, {
      status: 429,
      body: error_body
    })

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(faraday_error)

    response = @provider.fetch_security_prices(
      symbol: "AAPL",
      exchange_operating_mic: "XNAS",
      start_date: Date.parse("2024-01-01"),
      end_date: Date.parse("2024-01-10")
    )

    assert_not response.success?
    assert_match(/Custom rate limit message/, response.error.message)
  end
end
