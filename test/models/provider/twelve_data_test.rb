require "test_helper"

class Provider::TwelveDataTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = Provider::TwelveData.new("test_api_key")
  end

  # ================================
  #            Usage Tests
  # ================================

  def stub_usage(body)
    mock_response = mock
    mock_response.stubs(:body).returns(body.to_json)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)
  end

  test "usage reports utilization as a percentage of the daily limit" do
    stub_usage("plan_category" => "basic", "daily_usage" => 400, "plan_daily_limit" => 800)

    result = @provider.usage

    assert result.success?
    assert_equal 400, result.data.used
    assert_equal 800, result.data.limit
    assert_equal 50.0, result.data.utilization
  end

  test "usage keeps a fractional utilization below one percent" do
    stub_usage("plan_category" => "basic", "daily_usage" => 1, "plan_daily_limit" => 800)

    assert_equal 0.1, @provider.usage.data.utilization
  end

  test "usage fails when the daily limit is zero" do
    stub_usage("plan_category" => "basic", "daily_usage" => 5, "plan_daily_limit" => 0)

    result = @provider.usage

    assert_not result.success?
    assert_instance_of Provider::TwelveData::Error, result.error
  end

  test "usage fails when daily_usage is missing or not a number" do
    [ {}, { "daily_usage" => "abc" } ].each do |figures|
      stub_usage({ "plan_category" => "basic", "plan_daily_limit" => 800 }.merge(figures))

      assert_not @provider.usage.success?
    end
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

  # we-promise/sure#1187: the exchange_rate endpoint occasionally answers with
  # a zero rate, which used to be stored and zeroed converted balances.
  test "treats a zero rate from the single exchange rate endpoint as a failed lookup" do
    mock_response = mock
    mock_response.stubs(:body).returns({ "symbol" => "CHF/CNY", "rate" => 0.0, "timestamp" => Time.current.to_i }.to_json)

    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_exchange_rate(from: "CHF", to: "CNY", date: Date.current)

    assert_not result.success?
    assert_instance_of Provider::TwelveData::Error, result.error
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

  { 400 => Faraday::BadRequestError, 404 => Faraday::ResourceNotFound }.each do |status, error_class|
    test "falls back to the cross API when time_series rejects the pair with HTTP #{status}" do
      error_body = {
        "code" => status,
        "message" => "**symbol** or **figi** parameter is missing or invalid.",
        "status" => "error"
      }.to_json
      cross_response = mock
      cross_response.stubs(:body).returns({
        "values" => [ { "datetime" => "2026-10-28", "close" => "0.0102" } ],
        "status" => "ok"
      }.to_json)

      @provider.stubs(:throttle_request)
      mock_client = mock
      mock_client.expects(:get).with("https://api.twelvedata.com/time_series")
        .raises(error_class.new("the server responded with status #{status}", { status: status, body: error_body }))
      mock_client.expects(:get).with("https://api.twelvedata.com/time_series/cross").returns(cross_response)
      @provider.stubs(:client).returns(mock_client)

      result = @provider.fetch_exchange_rates(from: "KGS", to: "EUR", start_date: Date.new(2026, 10, 28), end_date: Date.new(2026, 10, 28))

      assert result.success?
      assert_equal 1, result.data.size
      assert_equal "KGS", result.data.first.from
      assert_equal "EUR", result.data.first.to
      assert_equal "0.0102", result.data.first.rate
    end
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

  test "default_error_transformer surfaces the real API message from a raised HTTP error body" do
    body = {
      "code" => 404,
      "message" => "This endpoint is not available for this symbol/exchange combination, available starting with Grow plan",
      "status" => "error"
    }.to_json
    error = Faraday::ResourceNotFound.new("the server responded with status 404 for GET https://api.twelvedata.com/time_series", { status: 404, body: body })

    result = @provider.send(:with_provider_response) { raise error }

    assert_not result.success?
    assert_instance_of Provider::TwelveData::Error, result.error
    assert_includes result.error.message, "available starting with Grow plan"
    assert Provider::TwelveData.plan_upgrade_required?(result.error.message)
    assert_equal "Grow", Provider::TwelveData.extract_required_plan(result.error.message)
  end

  test "default_error_transformer falls back to the generic Faraday message when the body isn't JSON" do
    error = Faraday::ResourceNotFound.new("the server responded with status 404 for GET https://api.twelvedata.com/time_series", { status: 404, body: "<html>Not Found</html>" })

    result = @provider.send(:with_provider_response) { raise error }

    assert_not result.success?
    assert_equal error.message, result.error.message
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

  # The tests above stub Rails.cache, and the test env uses a null store, so
  # they cannot notice a counter that is written but never read back. This one
  # runs against a real RedisCacheStore, the production cache store.
  test "throttle_request enforces the per-minute credit limit using a real Redis cache" do
    # A per-run namespace keeps the counter key unique, so concurrent or retried
    # runs sharing one Redis can never read each other's leftover counts.
    store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379"),
      namespace: "test:twelve_data:#{SecureRandom.hex(8)}"
    )
    Rails.stubs(:cache).returns(store)

    # Freeze 30s into a minute so the wait is predictable
    travel_to Time.utc(2026, 1, 1, 12, 0, 30) do
      minute_key = "twelve_data:credits:#{Time.current.to_i / 60}"

      sleeps = []
      @provider.define_singleton_method(:sleep) { |duration| sleeps << duration }

      with_env_overrides(TWELVE_DATA_MIN_REQUEST_INTERVAL: "0", TWELVE_DATA_MAX_REQUESTS_PER_MINUTE: "3") do
        3.times { @provider.send(:throttle_request) }
        assert_empty sleeps, "Should not wait while under the per-minute limit"

        @provider.send(:throttle_request)
        assert_equal [ 31 ], sleeps, "Should wait for the next minute once the limit is reached"
      end
    ensure
      store.delete(minute_key)
    end
  end

  test "client sets explicit open and read timeouts" do
    options = @provider.send(:client).options

    assert_equal 5, options.open_timeout
    assert_equal 20, options.timeout
  end

  test "a timed-out request returns a failed response with the provider's Error" do
    @provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, %r{\Ahttps://api\.twelvedata\.com/symbol_search}).to_timeout
    errors = capture_transformed_errors(@provider)

    response = @provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::TwelveData::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::ConnectionFailed, errors.last
    assert_kind_of Net::OpenTimeout, errors.last.wrapped_exception
  end

  test "a read timeout is retried and returns a failed response with the provider's Error" do
    @provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, %r{\Ahttps://api\.twelvedata\.com/symbol_search}).to_raise(Net::ReadTimeout)
    errors = capture_transformed_errors(@provider)

    response = @provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::TwelveData::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::TimeoutError, errors.last
  end

  test "time_series history requests get a longer read timeout than the client default" do
    @provider.stubs(:throttle_request)
    values = { "values" => [ { "datetime" => "2026-01-02", "close" => "1.5" } ], "meta" => { "currency" => "USD" } }.to_json
    stub_request(:get, %r{\Ahttps://api\.twelvedata\.com/time_series\?}).to_return(status: 200, body: values)
    # A pair time_series can't serve falls through to time_series/cross
    stub_request(:get, %r{\Ahttps://api\.twelvedata\.com/time_series\?})
      .with(query: hash_including("symbol" => "USD/ZZZ")).to_return(status: 200, body: {}.to_json)
    stub_request(:get, %r{\Ahttps://api\.twelvedata\.com/time_series/cross}).to_return(status: 200, body: values)
    stub_request(:get, %r{\Ahttps://api\.twelvedata\.com/symbol_search}).to_return(status: 200, body: { "data" => [] }.to_json)
    timeouts = capture_request_timeouts(@provider)

    @provider.fetch_security_prices(symbol: "AAPL", exchange_operating_mic: "XNAS", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 2))
    @provider.fetch_exchange_rates(from: "USD", to: "EUR", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 2))
    @provider.fetch_exchange_rates(from: "USD", to: "ZZZ", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 2))
    @provider.search_securities("AAPL")

    assert_requested :get, %r{\Ahttps://api\.twelvedata\.com/time_series/cross}, times: 1
    # prices, the EUR pair, the ZZZ pair and its cross fallback, then search
    assert_equal [ 60, 60, 60, 60, 20 ], timeouts
  end
end
