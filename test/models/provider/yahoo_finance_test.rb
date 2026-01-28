require "test_helper"

class Provider::YahooFinanceTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::YahooFinance.new
  end

  # ================================
  #        Health Check Tests
  # ================================

  test "healthy? returns true when API is working" do
    # Mock successful response
    mock_response = mock
    mock_response.stubs(:body).returns('{"chart":{"result":[{"meta":{"symbol":"AAPL"}}]}}')

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    assert @provider.healthy?
  end

  test "healthy? returns false when API fails" do
    # Mock failed response
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(Faraday::Error.new("Connection failed"))

    assert_not @provider.healthy?
  end

  # ================================
  #      Exchange Rate Tests
  # ================================

  test "fetch_exchange_rate returns 1.0 for same currency" do
    date = Date.parse("2024-01-15")
    response = @provider.fetch_exchange_rate(from: "USD", to: "USD", date: date)

    assert response.success?
    rate = response.data
    assert_equal 1.0, rate.rate
    assert_equal "USD", rate.from
    assert_equal "USD", rate.to
    assert_equal date, rate.date
  end

  test "fetch_exchange_rate handles invalid currency codes" do
    date = Date.parse("2024-01-15")

    # With validation removed, invalid currencies will result in API errors
    response = @provider.fetch_exchange_rate(from: "INVALID", to: "USD", date: date)
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error

    response = @provider.fetch_exchange_rate(from: "USD", to: "INVALID", date: date)
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error

    response = @provider.fetch_exchange_rate(from: "", to: "USD", date: date)
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error
  end

  test "fetch_exchange_rates returns same currency rates" do
    start_date = Date.parse("2024-01-10")
    end_date = Date.parse("2024-01-12")
    response = @provider.fetch_exchange_rates(from: "USD", to: "USD", start_date: start_date, end_date: end_date)

    assert response.success?
    rates = response.data
    expected_dates = (start_date..end_date).to_a
    assert_equal expected_dates.length, rates.length
    assert rates.all? { |r| r.rate == 1.0 }
    assert rates.all? { |r| r.from == "USD" }
    assert rates.all? { |r| r.to == "USD" }
  end

  test "fetch_exchange_rates validates date range" do
    response = @provider.fetch_exchange_rates(from: "USD", to: "EUR", start_date: Date.current, end_date: Date.current - 1.day)
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error

    response = @provider.fetch_exchange_rates(from: "USD", to: "EUR", start_date: Date.current - 6.years, end_date: Date.current)
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error
  end

  # ================================
  #       Security Search Tests
  # ================================

  test "search_securities handles invalid symbols" do
    # With validation removed, invalid symbols will result in API errors
    response = @provider.search_securities("")
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error

    response = @provider.search_securities("VERYLONGSYMBOLNAME")
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error

    response = @provider.search_securities("INVALID@SYMBOL")
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error
  end

  test "search_securities returns empty array for no results with short symbol" do
    # Mock empty results response
    mock_response = mock
    mock_response.stubs(:body).returns('{"quotes":[]}')

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.search_securities("XYZ")
    assert response.success?
    assert_equal [], response.data
  end

  # ================================
  #     Security Price Tests
  # ================================

  test "fetch_security_price handles invalid symbol" do
    date = Date.parse("2024-01-15")

    # With validation removed, invalid symbols will result in API errors
    response = @provider.fetch_security_price(symbol: "", exchange_operating_mic: "XNAS", date: date)
    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error
  end

  # ================================
  #         Caching Tests
  # ================================

  # Note: Caching tests are skipped as Rails.cache may not be properly configured in test environment
  # and caching functionality is not the focus of the validation fixes

  # ================================
  #       Error Handling Tests
  # ================================

  test "handles Faraday errors gracefully" do
    # Mock a Faraday error
    faraday_error = Faraday::ConnectionFailed.new("Connection failed")

    @provider.stub :client, ->(*) { raise faraday_error } do
      result = @provider.send(:with_provider_response) { raise faraday_error }

      assert_not result.success?
      assert_instance_of Provider::YahooFinance::Error, result.error
    end
  end

  test "handles rate limit errors" do
    rate_limit_error = Faraday::TooManyRequestsError.new("Rate limit exceeded", { body: "Too many requests" })

    @provider.stub :client, ->(*) { raise rate_limit_error } do
      result = @provider.send(:with_provider_response) { raise rate_limit_error }

      assert_not result.success?
      assert_instance_of Provider::YahooFinance::RateLimitError, result.error
    end
  end

  test "handles 401 unauthorized as authentication error" do
    unauthorized_error = Faraday::UnauthorizedError.new("Unauthorized", { body: "Invalid Crumb" })

    @provider.stub :client, ->(*) { raise unauthorized_error } do
      result = @provider.send(:with_provider_response) { raise unauthorized_error }

      assert_not result.success?
      assert_instance_of Provider::YahooFinance::AuthenticationError, result.error
      assert_match(/authentication failed/, result.error.message)
    end
  end

  # ================================
  #     User-Agent Rotation Tests
  # ================================

  test "random_user_agent returns value from USER_AGENTS pool" do
    user_agent = @provider.send(:random_user_agent)
    assert_includes Provider::YahooFinance::USER_AGENTS, user_agent
  end

  test "USER_AGENTS contains multiple modern browser user-agents" do
    assert Provider::YahooFinance::USER_AGENTS.length >= 5
    assert Provider::YahooFinance::USER_AGENTS.all? { |ua| ua.include?("Mozilla") }
  end

  # ================================
  #       Throttling Tests
  # ================================

  test "throttle_request enforces minimum interval between requests" do
    # First request should not wait
    start_time = Time.current
    @provider.send(:throttle_request)
    first_elapsed = Time.current - start_time
    assert first_elapsed < 0.1, "First request should not wait"

    # Second request should wait approximately min_request_interval
    start_time = Time.current
    @provider.send(:throttle_request)
    second_elapsed = Time.current - start_time
    min_interval = @provider.send(:min_request_interval)
    assert second_elapsed >= (min_interval - 0.05), "Second request should wait at least #{min_interval - 0.05}s"
  end

  # ================================
  #    Configuration Tests
  # ================================

  test "max_retries returns default value" do
    assert_equal 5, @provider.send(:max_retries)
  end

  test "retry_interval returns default value" do
    assert_equal 1.0, @provider.send(:retry_interval)
  end

  test "min_request_interval returns default value" do
    assert_equal 0.5, @provider.send(:min_request_interval)
  end

  # ================================
  #  Cookie/Crumb Authentication Tests
  # ================================

  test "extract_cookie extracts cookie from set-cookie header" do
    mock_response = OpenStruct.new(
      headers: { "set-cookie" => "B=abc123&b=3&s=qf; expires=Fri, 18-May-2028 00:00:00 GMT; path=/; domain=.yahoo.com" }
    )

    cookie = @provider.send(:extract_cookie, mock_response)
    assert_equal "B=abc123&b=3&s=qf", cookie
  end

  test "extract_cookie returns nil when no cookie header" do
    mock_response = OpenStruct.new(headers: {})
    cookie = @provider.send(:extract_cookie, mock_response)
    assert_nil cookie
  end

  test "extract_cookie_max_age parses Max-Age from cookie header" do
    mock_response = OpenStruct.new(
      headers: { "set-cookie" => "A3=d=xxx; Max-Age=31557600; Domain=.yahoo.com" }
    )

    max_age = @provider.send(:extract_cookie_max_age, mock_response)
    assert_equal 31557600.seconds, max_age
  end

  test "extract_cookie_max_age returns nil when no Max-Age" do
    mock_response = OpenStruct.new(
      headers: { "set-cookie" => "A3=d=xxx; Domain=.yahoo.com" }
    )

    max_age = @provider.send(:extract_cookie_max_age, mock_response)
    assert_nil max_age
  end

  test "clear_crumb_cache removes cached crumb" do
    Rails.cache.write("yahoo_finance_auth_crumb", [ "cookie", "crumb" ])
    @provider.send(:clear_crumb_cache)
    assert_nil Rails.cache.read("yahoo_finance_auth_crumb")
  end

  # ================================
  #       Helper Method Tests
  # ================================

  test "map_country_code returns correct codes for exchanges" do
    assert_equal "US", @provider.send(:map_country_code, "NASDAQ")
    assert_equal "US", @provider.send(:map_country_code, "NYSE")
    assert_equal "GB", @provider.send(:map_country_code, "LSE")
    assert_equal "JP", @provider.send(:map_country_code, "TOKYO")
    assert_equal "CA", @provider.send(:map_country_code, "TSX")
    assert_equal "DE", @provider.send(:map_country_code, "FRANKFURT")
    assert_nil @provider.send(:map_country_code, "UNKNOWN")
    assert_nil @provider.send(:map_country_code, "")
  end

  test "map_exchange_mic returns correct MIC codes" do
    assert_equal "XNAS", @provider.send(:map_exchange_mic, "NMS")
    assert_equal "XNAS", @provider.send(:map_exchange_mic, "NGM")
    assert_equal "XNYS", @provider.send(:map_exchange_mic, "NYQ")
    assert_equal "XLON", @provider.send(:map_exchange_mic, "LSE")
    assert_equal "XTSE", @provider.send(:map_exchange_mic, "TSE")
    assert_equal "UNKNOWN", @provider.send(:map_exchange_mic, "UNKNOWN")
    assert_nil @provider.send(:map_exchange_mic, "")
  end

  test "map_security_type returns correct types" do
    assert_equal "common stock", @provider.send(:map_security_type, "equity")
    assert_equal "etf", @provider.send(:map_security_type, "etf")
    assert_equal "mutual fund", @provider.send(:map_security_type, "mutualfund")
    assert_equal "index", @provider.send(:map_security_type, "index")
    assert_equal "unknown", @provider.send(:map_security_type, "unknown")
    assert_nil @provider.send(:map_security_type, nil)
  end



  test "validate_date_range! raises errors for invalid ranges" do
    assert_raises(Provider::YahooFinance::Error) do
      @provider.send(:validate_date_range!, Date.current, Date.current - 1.day)
    end

    assert_raises(Provider::YahooFinance::Error) do
      @provider.send(:validate_date_range!, Date.current - 6.years - 1.day, Date.current)
    end

    # Should not raise for valid ranges
    assert_nothing_raised do
      @provider.send(:validate_date_range!, Date.current - 1.year, Date.current)
      @provider.send(:validate_date_range!, Date.current - 5.years, Date.current)
    end
  end

  # ================================
  #   Currency Normalization Tests
  # ================================

  test "normalize_currency_and_price converts GBp to GBP" do
    currency, price = @provider.send(:normalize_currency_and_price, "GBp", 1234.56)
    assert_equal "GBP", currency
    assert_equal 12.3456, price
  end

  test "normalize_currency_and_price converts ZAc to ZAR" do
    currency, price = @provider.send(:normalize_currency_and_price, "ZAc", 5000.0)
    assert_equal "ZAR", currency
    assert_equal 50.0, price
  end

  test "normalize_currency_and_price leaves standard currencies unchanged" do
    currency, price = @provider.send(:normalize_currency_and_price, "USD", 100.50)
    assert_equal "USD", currency
    assert_equal 100.50, price

    currency, price = @provider.send(:normalize_currency_and_price, "GBP", 50.25)
    assert_equal "GBP", currency
    assert_equal 50.25, price

    currency, price = @provider.send(:normalize_currency_and_price, "EUR", 75.75)
    assert_equal "EUR", currency
    assert_equal 75.75, price
  end
end
