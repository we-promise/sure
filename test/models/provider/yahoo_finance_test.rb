require "test_helper"

class Provider::YahooFinanceTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::YahooFinance.new
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    DebugLogEntry.stubs(:capture)
  end

  # ================================
  #        Health Check Tests
  # ================================

  test "health_status caches a healthy provider assessment" do
    stub_successful_health_authentication
    stub_health_chart_responses(healthy_chart_response)

    assert_equal :healthy, @provider.health_status
    assert_equal :healthy, @provider.health_status
  end

  test "health_status classifies a crumb HTTP 429 without retrying" do
    cookie_response = health_response(
      status: 404,
      headers: { "set-cookie" => "A3=test-cookie; Max-Age=3600" }
    )
    crumb_response = health_response(status: 429, body: "secret response body")
    auth_client = mock
    auth_client.expects(:get).twice.returns(cookie_response, crumb_response)
    @provider.stubs(:health_auth_client).returns(auth_client)
    @provider.expects(:health_authenticated_client).never

    assert_equal :rate_limited, @provider.health_status
  end

  test "health_status classifies a cookie HTTP 429 without continuing crumb acquisition" do
    auth_client = mock
    auth_client.expects(:get).once.returns(health_response(status: 429, body: "secret response body"))
    @provider.stubs(:health_auth_client).returns(auth_client)
    @provider.expects(:health_authenticated_client).never

    assert_equal :rate_limited, @provider.health_status
  end

  test "health_status classifies a chart HTTP 429 without retrying" do
    stub_successful_health_authentication
    stub_health_chart_responses(health_response(status: 429, body: "secret response body"))

    assert_equal :rate_limited, @provider.health_status
  end

  test "health_status classifies connection failures and timeouts as unavailable" do
    [ Faraday::ConnectionFailed.new("connection failed"), Faraday::TimeoutError.new("timed out") ].each do |error|
      provider = Provider::YahooFinance.new
      @cache.clear
      auth_client = mock
      auth_client.expects(:get).once.raises(error)
      provider.stubs(:health_auth_client).returns(auth_client)

      assert_equal :unavailable, provider.health_status
    end
  end

  test "health_status clears Unauthorized credentials without retrying immediately" do
    auth_client = mock
    auth_client.expects(:get).times(4).returns(
      cookie_health_response("cookie-1"), health_response(status: 200, body: "crumb-1"),
      cookie_health_response("cookie-2"), health_response(status: 200, body: "crumb-2")
    )
    @provider.stubs(:health_auth_client).returns(auth_client)
    stub_health_chart_responses(
      health_response(status: 200, body: '{"chart":{"error":{"code":"Unauthorized"}}}'),
      healthy_chart_response
    )

    travel_to Time.zone.parse("2026-07-20 12:00:00") do
      assert_equal :unavailable, @provider.health_status
      travel 5.minutes + 1.second
      assert_equal :healthy, @provider.health_status
    end
  end

  test "health_status classifies malformed and empty chart responses as unavailable" do
    stub_successful_health_authentication
    stub_health_chart_responses(
      health_response(status: 200, body: "not-json"),
      health_response(status: 200, body: '{"chart":{"result":[]}}')
    )

    travel_to Time.zone.parse("2026-07-20 12:00:00") do
      assert_equal :unavailable, @provider.health_status
      travel 5.minutes + 1.second
      assert_equal :unavailable, @provider.health_status
    end
  end

  test "health_status applies status-specific freshness windows" do
    [
      [ healthy_chart_response, 15.minutes, :healthy ],
      [ health_response(status: 429), 30.minutes, :rate_limited ],
      [ health_response(status: 503), 5.minutes, :unavailable ]
    ].each do |first_response, freshness, first_status|
      provider = Provider::YahooFinance.new
      @cache.clear
      stub_successful_health_authentication(provider: provider)
      stub_health_chart_responses(first_response, healthy_chart_response, provider: provider)

      travel_to Time.zone.parse("2026-07-20 12:00:00") do
        assert_equal first_status, provider.health_status
        travel freshness - 1.second
        assert_equal first_status, provider.health_status
        travel 2.seconds
        assert_equal :healthy, provider.health_status
      end
    end
  end

  test "health_status returns stale evidence while one refresh is in progress" do
    stub_successful_health_authentication
    started = Queue.new
    finish = Queue.new
    calls = 0
    chart_client = Object.new
    chart_client.define_singleton_method(:get) do |*_args|
      calls += 1
      next healthy_chart_response if calls == 1

      started << true
      finish.pop
      health_response(status: 503)
    end
    chart_client.define_singleton_method(:healthy_chart_response) { health_response(status: 200, body: '{"chart":{"result":[{}]}}') }
    chart_client.define_singleton_method(:health_response) do |status:, body: ""|
      OpenStruct.new(status: status, body: body, headers: {}, success?: status.between?(200, 299))
    end
    @provider.stubs(:health_authenticated_client).returns(chart_client)

    travel_to Time.zone.parse("2026-07-20 12:00:00") do
      assert_equal :healthy, @provider.health_status
      travel 15.minutes + 1.second

      refreshing = Thread.new { @provider.health_status }
      started.pop
      assert_equal :healthy, Provider::YahooFinance.new.health_status
      finish << true
      assert_equal :unavailable, refreshing.value
    end
  end

  test "health_status returns unknown during a cold concurrent refresh" do
    stub_successful_health_authentication
    started = Queue.new
    finish = Queue.new
    chart_client = Object.new
    response = healthy_chart_response
    chart_client.define_singleton_method(:get) do |*_args|
      started << true
      finish.pop
      response
    end
    @provider.stubs(:health_authenticated_client).returns(chart_client)

    refreshing = Thread.new { @provider.health_status }
    started.pop
    assert_equal :unknown, Provider::YahooFinance.new.health_status
    finish << true
    assert_equal :healthy, refreshing.value
  end

  test "health_status discards stale evidence after one hour" do
    stub_successful_health_authentication(count: 2)
    started = Queue.new
    finish = Queue.new
    calls = 0
    first_response = healthy_chart_response
    refresh_response = healthy_chart_response
    chart_client = Object.new
    chart_client.define_singleton_method(:get) do |*_args|
      calls += 1
      next first_response if calls == 1

      started << true
      finish.pop
      refresh_response
    end
    @provider.stubs(:health_authenticated_client).returns(chart_client)

    travel_to Time.zone.parse("2026-07-20 12:00:00") do
      assert_equal :healthy, @provider.health_status
      travel 1.hour + 1.second

      refreshing = Thread.new { @provider.health_status }
      started.pop
      assert_equal :unknown, Provider::YahooFinance.new.health_status
      finish << true
      assert_equal :healthy, refreshing.value
    end
  end

  test "health_status lock expires and an obsolete refresh cannot overwrite newer evidence" do
    stub_successful_health_authentication
    started = Queue.new
    finish = Queue.new
    obsolete_response = health_response(status: 503)
    blocking_client = Object.new
    blocking_client.define_singleton_method(:get) do |*_args|
      started << true
      finish.pop
      obsolete_response
    end
    @provider.stubs(:health_authenticated_client).returns(blocking_client)

    first_refresh = Thread.new { @provider.health_status }
    started.pop
    travel 15.seconds + 1.second do
      replacement = Provider::YahooFinance.new
      stub_health_chart_responses(healthy_chart_response, provider: replacement)
      assert_equal :healthy, replacement.health_status
    end
    finish << true

    assert_equal :healthy, first_refresh.value
    assert_equal :healthy, Provider::YahooFinance.new.health_status
  end

  test "health_status returns unknown without contacting Yahoo when cache access fails" do
    failing_cache = mock
    failing_cache.expects(:read).once.raises(Redis::BaseError.new("cache details"))
    Rails.stubs(:cache).returns(failing_cache)
    @provider.expects(:perform_health_check).never
    DebugLogEntry.expects(:capture).with do |attributes|
      attributes[:category] == "provider_health_cache" &&
        attributes[:metadata] == { exception_class: "Redis::BaseError" } &&
        attributes.to_s.exclude?("cache details")
    end

    assert_equal :unknown, @provider.health_status
  end

  test "health_status reports a credential-cache failure as unknown" do
    backing_cache = @cache
    read_count = 0
    failing_cache = Object.new
    failing_cache.define_singleton_method(:read) do |key|
      read_count += 1
      raise Redis::BaseError, "cache details" if read_count == 3

      backing_cache.read(key)
    end
    failing_cache.define_singleton_method(:write) { |key, value, **options| backing_cache.write(key, value, **options) }
    failing_cache.define_singleton_method(:delete) { |key| backing_cache.delete(key) }
    Rails.stubs(:cache).returns(failing_cache)
    @provider.expects(:health_auth_client).never

    diagnostics = []
    DebugLogEntry.stubs(:capture).with { |attributes| diagnostics << attributes }

    assert_equal :unknown, @provider.health_status
    assert_equal [ "provider_health_cache" ], diagnostics.map { |entry| entry[:category] }
    assert diagnostics.none? { |entry| entry.to_s.include?("cache details") }
  end

  test "health_status records only safe state transitions" do
    stub_successful_health_authentication
    stub_health_chart_responses(health_response(status: 429, body: "secret-body"))
    DebugLogEntry.expects(:capture).with do |attributes|
      attributes[:category] == "provider_health" &&
        attributes[:level] == "warn" &&
        attributes[:metadata] == {
          previous_state: :unknown,
          new_state: :rate_limited,
          health_check_stage: :chart,
          http_status: 429
        } &&
        attributes.to_s.exclude?("secret-body")
    end

    assert_equal :rate_limited, @provider.health_status
  end

  test "health_status omits repeated diagnostics and records healthy recovery" do
    stub_successful_health_authentication(count: 2)
    stub_health_chart_responses(
      health_response(status: 429),
      health_response(status: 429),
      healthy_chart_response
    )
    events = []
    DebugLogEntry.stubs(:capture).with { |attributes| events << attributes }

    travel_to Time.zone.parse("2026-07-20 12:00:00") do
      assert_equal :rate_limited, @provider.health_status
      travel 30.minutes + 1.second
      assert_equal :rate_limited, @provider.health_status
      travel 30.minutes + 1.second
      assert_equal :healthy, @provider.health_status
    end

    assert_equal %i[rate_limited healthy], events.map { |event| event.dig(:metadata, :new_state) }
    assert_equal %w[warn info], events.map { |event| event[:level] }
  end

  test "healthy? is true only for healthy" do
    %i[healthy rate_limited unavailable unknown].each do |status|
      provider = Provider::YahooFinance.new
      provider.stubs(:health_status).returns(status)

      assert_equal status == :healthy, provider.healthy?
    end
  end

  test "rate-limited health status does not gate or change normal price and exchange-rate operations" do
    stub_successful_health_authentication
    stub_health_chart_responses(health_response(status: 429))
    assert_equal :rate_limited, @provider.health_status

    @provider.stubs(:fetch_authenticated_chart).returns(
      "chart" => {
        "result" => [ {
          "meta" => { "currency" => "USD", "exchangeName" => "NMS" },
          "timestamp" => [ Time.utc(2026, 7, 17).to_i ],
          "indicators" => { "quote" => [ { "close" => [ 210.25 ] } ] }
        } ]
      }
    )
    @provider.stubs(:throttle_request)

    price_response = @provider.fetch_security_prices(
      symbol: "AAPL",
      exchange_operating_mic: "XNAS",
      start_date: Date.new(2026, 7, 17),
      end_date: Date.new(2026, 7, 17)
    )
    exchange_rate_response = @provider.fetch_exchange_rates(
      from: "USD",
      to: "EUR",
      start_date: Date.new(2026, 7, 17),
      end_date: Date.new(2026, 7, 17)
    )

    assert price_response.success?
    assert exchange_rate_response.success?
    assert_equal :rate_limited, @provider.health_status
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

  test "search_securities returns canonical Colombian identity for Yahoo BVC listings" do
    mock_response = mock
    mock_response.stubs(:body).returns({
      quotes: [ {
        symbol: "CIBEST.CL",
        longname: "Grupo Cibest S.A.",
        exchange: "BVC",
        exchDisp: "Colombia"
      } ]
    }.to_json)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.search_securities("CIBEST.CL")

    assert response.success?
    security = response.data.sole
    assert_equal "CIBEST.CL", security.symbol
    assert_equal "XBOG", security.exchange_operating_mic
    assert_equal "CO", security.country_code
  end

  test "search_securities preserves catalog countries and display-name fallback" do
    mock_response = mock
    mock_response.stubs(:body).returns({
      quotes: [
        { symbol: "AAPL", shortname: "Apple", exchange: "NMS", exchDisp: "NASDAQ" },
        { symbol: "SAP.F", shortname: "SAP", exchange: "FRA", exchDisp: "Frankfurt" },
        { symbol: "FALLBACK", shortname: "Fallback", exchange: "UNKNOWN", exchDisp: "Frankfurt" }
      ]
    }.to_json)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.search_securities("company")

    assert response.success?
    results_by_symbol = response.data.index_by(&:symbol)
    assert_equal "US", results_by_symbol.fetch("AAPL").country_code
    assert_equal "DE", results_by_symbol.fetch("SAP.F").country_code
    assert_equal "DE", results_by_symbol.fetch("FALLBACK").country_code
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

  test "fetch_security_prices uses the Colombian Yahoo suffix once and COP fallback" do
    date = Date.new(2024, 1, 15)
    chart_response = mock
    chart_response.stubs(:body).returns({
      chart: {
        result: [ {
          meta: { exchangeName: "BVC" },
          timestamp: [ Time.utc(2024, 1, 15).to_i ],
          indicators: { quote: [ { close: [ 42_350.0 ] } ] }
        } ]
      }
    }.to_json)
    chart_client = mock
    chart_client.expects(:get).with(regexp_matches(%r{/v8/finance/chart/CIBEST\.CL$})).twice.returns(chart_response)
    @provider.stubs(:fetch_cookie_and_crumb).returns([ "cookie", "crumb" ])
    @provider.stubs(:authenticated_client).with("cookie").returns(chart_client)
    @provider.stubs(:throttle_request)

    responses = [ "CIBEST", "CIBEST.CL" ].map do |symbol|
      @provider.fetch_security_prices(
        symbol: symbol,
        exchange_operating_mic: "XBOG",
        start_date: date,
        end_date: date
      )
    end

    responses.each do |response|
      assert response.success?
      price = response.data.sole
      assert_equal "CIBEST.CL", price.symbol
      assert_equal "COP", price.currency
      assert_equal "XBOG", price.exchange_operating_mic
    end
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

  test "classifies a successful crumb response containing a rate limit body" do
    cookie_response = mock
    cookie_response.stubs(:headers).returns({ "set-cookie" => "A3=test-cookie; Max-Age=3600" })

    crumb_response = mock
    crumb_response.stubs(:status).returns(200)
    crumb_response.stubs(:body).returns("Too Many Requests")
    crumb_response.stubs(:success?).returns(true)

    auth_client = mock
    auth_client.stubs(:get).returns(cookie_response, crumb_response)
    @provider.stubs(:auth_client).returns(auth_client)
    @provider.stubs(:throttle_request)

    result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS")

    assert_not result.success?
    assert_instance_of Provider::YahooFinance::RateLimitError, result.error
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

  # ================================
  #   Exchange Mapping Tests
  # ================================

  test "map_exchange_mic returns XNSE for NSE and NSI" do
    assert_equal "XNSE", @provider.send(:map_exchange_mic, "NSE")
    assert_equal "XNSE", @provider.send(:map_exchange_mic, "NSI")
    assert_equal "XNSE", @provider.send(:map_exchange_mic, "nse")
  end

  test "map_exchange_mic returns XBOM for BSE and BOM" do
    assert_equal "XBOM", @provider.send(:map_exchange_mic, "BSE")
    assert_equal "XBOM", @provider.send(:map_exchange_mic, "BOM")
  end

  test "map_country_code returns IN for Indian exchanges" do
    assert_equal "IN", @provider.send(:map_country_code, "NSE")
    assert_equal "IN", @provider.send(:map_country_code, "BSE")
    assert_equal "IN", @provider.send(:map_country_code, "MUMBAI")
  end

  # ================================
  #   normalize_symbol Tests
  # ================================

  test "normalize_symbol appends configured suffix for known MICs" do
    assert_equal "RELIANCE.NS", @provider.send(:normalize_symbol, "RELIANCE", "XNSE")
    assert_equal "INFY.NS",     @provider.send(:normalize_symbol, "INFY", "XNSE")
    assert_equal "500325.BO",   @provider.send(:normalize_symbol, "500325", "XBOM")
  end

  test "normalize_symbol does not double-suffix already suffixed symbols" do
    assert_equal "RELIANCE.NS", @provider.send(:normalize_symbol, "RELIANCE.NS", "XNSE")
    assert_equal "500325.BO",   @provider.send(:normalize_symbol, "500325.BO", "XBOM")
  end

  test "normalize_symbol leaves unconfigured MIC symbols unchanged" do
    assert_equal "AAPL", @provider.send(:normalize_symbol, "AAPL", "XNAS")
    assert_equal "BARC", @provider.send(:normalize_symbol, "BARC", "XLON")
    assert_equal "AAPL", @provider.send(:normalize_symbol, "AAPL", nil)
  end

  test "normalize_symbol appends suffix to dotted symbols that do not already end with the configured suffix" do
    assert_equal "BRK.A.NS", @provider.send(:normalize_symbol, "BRK.A", "XNSE")
    assert_equal "BRK.B.BO", @provider.send(:normalize_symbol, "BRK.B", "XBOM")
  end

  # ================================
  #  default_currency_for_exchange Tests
  # ================================

  test "default_currency_for_exchange returns configured currency for known Yahoo exchange names" do
    assert_equal "INR", @provider.send(:default_currency_for_exchange, "NSE")
    assert_equal "INR", @provider.send(:default_currency_for_exchange, "BSE")
  end

  test "default_currency_for_exchange returns nil for unknown exchanges" do
    assert_nil @provider.send(:default_currency_for_exchange, "UNKNOWN")
    assert_nil @provider.send(:default_currency_for_exchange, "NMS")
  end

  # ================================
  #  deduplicate_dual_listings Tests
  # ================================

  test "deduplicate_dual_listings keeps preferred exchange when both are present" do
    nse = Provider::SecurityConcept::Security.new(symbol: "RELIANCE.NS", name: "Reliance", logo_url: nil, exchange_operating_mic: "XNSE", country_code: "IN")
    bse = Provider::SecurityConcept::Security.new(symbol: "500325.BO",   name: "Reliance", logo_url: nil, exchange_operating_mic: "XBOM", country_code: "IN")
    other = Provider::SecurityConcept::Security.new(symbol: "OTHER", name: "Other", logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US")

    result = @provider.send(:deduplicate_dual_listings, [ nse, bse, other ])

    assert_equal "XNSE", result.first.exchange_operating_mic
    assert_not result.map(&:exchange_operating_mic).include?("XBOM"), "Lower-ranked exchange should be removed"
    assert result.map(&:exchange_operating_mic).include?("XNAS"), "Non-dual-listed exchanges should be preserved"
  end

  test "deduplicate_dual_listings preserves unrelated securities in the same dual_list_group" do
    reliance_nse = Provider::SecurityConcept::Security.new(symbol: "RELIANCE.NS", name: "Reliance Industries", logo_url: nil, exchange_operating_mic: "XNSE", country_code: "IN")
    reliance_bse = Provider::SecurityConcept::Security.new(symbol: "500325.BO",   name: "Reliance Industries", logo_url: nil, exchange_operating_mic: "XBOM", country_code: "IN")
    infy_nse     = Provider::SecurityConcept::Security.new(symbol: "INFY.NS",     name: "Infosys",             logo_url: nil, exchange_operating_mic: "XNSE", country_code: "IN")
    other        = Provider::SecurityConcept::Security.new(symbol: "AAPL",        name: "Apple",               logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US")

    result = @provider.send(:deduplicate_dual_listings, [ reliance_nse, reliance_bse, infy_nse, other ])

    symbols = result.map(&:symbol)
    assert_includes symbols, "RELIANCE.NS", "Preferred listing should be kept"
    assert_not_includes symbols, "500325.BO", "Duplicate listing should be removed"
    assert_includes symbols, "INFY.NS", "Unrelated security in same group should be preserved"
    assert_includes symbols, "AAPL", "Non-dual-listed security should be preserved"
    assert_equal 3, result.size
  end

  test "deduplicate_dual_listings returns original list when no dual-listed exchanges present" do
    securities = [
      Provider::SecurityConcept::Security.new(symbol: "AAPL", name: "Apple", logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US"),
      Provider::SecurityConcept::Security.new(symbol: "MSFT", name: "Microsoft", logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US")
    ]

    result = @provider.send(:deduplicate_dual_listings, securities)
    assert_equal securities, result
  end

  private

    def stub_successful_health_authentication(provider: @provider, count: 1)
      responses = count.times.flat_map do |index|
        [
          cookie_health_response("test-cookie-#{index}"),
          health_response(status: 200, body: "test-crumb-#{index}")
        ]
      end
      auth_client = mock
      auth_client.expects(:get).times(responses.length).returns(*responses)
      provider.stubs(:health_auth_client).returns(auth_client)
    end

    def stub_health_chart_responses(*responses, provider: @provider)
      chart_client = mock
      chart_client.expects(:get).times(responses.length).returns(*responses)
      provider.stubs(:health_authenticated_client).returns(chart_client)
    end

    def cookie_health_response(cookie)
      health_response(
        status: 404,
        headers: { "set-cookie" => "A3=#{cookie}; Max-Age=3600" }
      )
    end

    def healthy_chart_response
      health_response(
        status: 200,
        body: '{"chart":{"result":[{"meta":{"symbol":"AAPL"}}]}}'
      )
    end

    def health_response(status:, body: "", headers: {})
      OpenStruct.new(
        status: status,
        body: body,
        headers: headers,
        success?: status.between?(200, 299)
      )
    end
end
