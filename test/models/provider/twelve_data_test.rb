require "test_helper"

class Provider::TwelveDataTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::TwelveData.new("test_api_key")
  end

  # ================================
  #     Rate Limit Detection Tests
  # ================================

  test "detects rate limit from JSON body code 429" do
    rate_limit_body = {
      "code" => 429,
      "message" => "You have run out of API credits for the current minute.",
      "status" => "error"
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(rate_limit_body)

    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_exchange_rates(from: "USD", to: "EUR", start_date: Date.current, end_date: Date.current)

    assert_not result.success?
    assert_instance_of Provider::TwelveData::RateLimitError, result.error
  end

  test "detects rate limit on single exchange rate fetch" do
    rate_limit_body = {
      "code" => 429,
      "message" => "Rate limit exceeded"
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(rate_limit_body)

    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_exchange_rate(from: "USD", to: "EUR", date: Date.current)

    assert_not result.success?
    assert_instance_of Provider::TwelveData::RateLimitError, result.error
  end

  test "does not fall through to cross API when rate limited" do
    rate_limit_body = {
      "code" => 429,
      "message" => "Rate limit exceeded"
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(rate_limit_body)

    @provider.stubs(:throttle_request)
    mock_client = mock
    # Should only be called once (time_series), NOT a second time (time_series/cross)
    mock_client.expects(:get).once.returns(mock_response)
    @provider.stubs(:client).returns(mock_client)

    result = @provider.fetch_exchange_rates(from: "USD", to: "EUR", start_date: Date.current, end_date: Date.current)

    assert_not result.success?
    assert_instance_of Provider::TwelveData::RateLimitError, result.error
  end

  # ================================
  #   Error Transformer Tests
  # ================================

  test "default_error_transformer preserves RateLimitError" do
    error = Provider::TwelveData::RateLimitError.new("Rate limit exceeded")

    result = @provider.send(:with_provider_response) { raise error }

    assert_not result.success?
    assert_instance_of Provider::TwelveData::RateLimitError, result.error
  end

  test "default_error_transformer converts Faraday 429 to RateLimitError" do
    error = Faraday::TooManyRequestsError.new("Too Many Requests", { body: "Rate limited" })

    result = @provider.send(:with_provider_response) { raise error }

    assert_not result.success?
    assert_instance_of Provider::TwelveData::RateLimitError, result.error
  end

  test "default_error_transformer wraps generic errors as Error" do
    error = StandardError.new("Something went wrong")

    result = @provider.send(:with_provider_response) { raise error }

    assert_not result.success?
    assert_instance_of Provider::TwelveData::Error, result.error
  end

  # ================================
  #     Crypto Filter Tests
  # ================================

  test "search_securities excludes Digital Currency rows" do
    body = {
      "data" => [
        {
          "symbol" => "ETH",
          "instrument_name" => "Grayscale Ethereum Trust ETF",
          "mic_code" => "ARCX",
          "instrument_type" => "ETF",
          "country" => "United States",
          "currency" => "USD"
        },
        {
          "symbol" => "ETH/EUR",
          "instrument_name" => "Ethereum Euro",
          "mic_code" => "DIGITAL_CURRENCY",
          "instrument_type" => "Digital Currency",
          "country" => "",
          "currency" => ""
        },
        {
          "symbol" => "BTC/USD",
          "instrument_name" => "Bitcoin US Dollar",
          "mic_code" => "DIGITAL_CURRENCY",
          "instrument_type" => "Digital Currency",
          "country" => "",
          "currency" => ""
        }
      ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("ETH")

    assert result.success?
    assert_equal 1, result.data.size
    assert_equal "ETH", result.data.first.symbol
    refute result.data.any? { |s| s.symbol.include?("/") }
  end

  test "search_securities excludes crypto even with mixed-case instrument_type" do
    body = {
      "data" => [
        {
          "symbol" => "BTC/EUR",
          "instrument_name" => "Bitcoin Euro",
          "mic_code" => "",
          "instrument_type" => "digital currency",
          "currency" => ""
        }
      ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("BTC")
    assert_empty result.data
  end

  # ================================
  #       Throttle Tests
  # ================================

  test "throttle_request enforces minimum interval between calls" do
    @provider.send(:instance_variable_set, :@last_request_time, Time.current)

    # Stub sleep to capture the call without actually sleeping
    sleep_called_with = nil
    @provider.define_singleton_method(:sleep) { |duration| sleep_called_with = duration }

    # Stub cache to return under limit (read returns current count, increment charges)
    Rails.cache.stubs(:read).returns(0)
    Rails.cache.stubs(:increment).returns(1)

    @provider.send(:throttle_request)

    assert_not_nil sleep_called_with, "Should have called sleep to enforce minimum interval"
    assert_operator sleep_called_with, :>, 0
  end

  test "throttle_request waits when per-minute credit limit is exceeded" do
    # Stub cache read to return count at limit (adding 1 more would exceed 7)
    Rails.cache.stubs(:read).returns(7)
    Rails.cache.stubs(:increment).returns(8)

    sleep_called = false
    @provider.define_singleton_method(:sleep) { |_duration| sleep_called = true }

    @provider.send(:throttle_request)

    assert sleep_called, "Should have called sleep when credit limit exceeded"
  end

  test "throttle_request does not wait when under credit limit" do
    # Set last_request_time far in the past so per-instance throttle doesn't trigger
    @provider.send(:instance_variable_set, :@last_request_time, Time.at(0))

    # Stub cache to return under limit
    Rails.cache.stubs(:read).returns(3)
    Rails.cache.stubs(:increment).returns(4)

    sleep_called = false
    @provider.define_singleton_method(:sleep) { |_duration| sleep_called = true }

    @provider.send(:throttle_request)

    assert_not sleep_called, "Should not sleep when under credit limit"
  end
end
