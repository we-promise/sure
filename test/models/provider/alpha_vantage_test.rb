require "test_helper"

class Provider::AlphaVantageTest < ActiveSupport::TestCase
  include ProviderTestHelper

  OVERVIEW_URL = "https://www.alphavantage.co/query".freeze

  setup do
    @provider = Provider::AlphaVantage.new("test_api_key")
  end

  # The test environment caches in a null store, so the usage readers need a real
  # RedisCacheStore to notice a counter they cannot read back. The per-run namespace
  # keeps runs sharing one Redis from reading each other's counts.
  test "usage reports the request counter on a real Redis cache" do
    store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379"),
      namespace: "test:alpha_vantage:#{SecureRandom.hex(8)}"
    )
    Rails.stubs(:cache).returns(store)

    provider = Provider::AlphaVantage.new("test_api_key")
    provider.define_singleton_method(:sleep) { |_duration| }
    2.times { provider.send(:throttle_request) }

    assert_equal 2, provider.usage.data.used
  ensure
    store&.delete("alpha_vantage:daily:#{Date.current}")
  end

  test "every attempt of a request is counted against the daily limit, including retries" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:sleep)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)

    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW"))
      .to_raise(Faraday::TimeoutError).then
      .to_raise(Faraday::TimeoutError).then
      .to_return(status: 200, body: { "Name" => "Apple Inc", "Symbol" => "AAPL" }.to_json)

    assert @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?

    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW"), times: 3
    assert_equal 3, Rails.cache.read("alpha_vantage:daily:#{Date.current}")
  end

  test "a retry that would exceed the daily limit is refused before reaching Alpha Vantage" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    @provider.stubs(:sleep)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    store.write("alpha_vantage:daily:#{Date.current}", 24)

    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW"))
      .to_raise(Faraday::TimeoutError)

    result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS")

    assert_not result.success?
    assert_kind_of Provider::AlphaVantage::RateLimitError, result.error
    # The first attempt is counted (24 -> 25) and reaches the wire; the retry is counted
    # past the limit (25 -> 26) and refused before it
    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW"), times: 1
    assert_equal 26, store.read("alpha_vantage:daily:#{Date.current}")
  end

  test "client sets explicit open and read timeouts" do
    provider = Provider::AlphaVantage.new("test_api_key")
    options = provider.send(:client).options

    assert_equal 5, options.open_timeout
    assert_equal 20, options.timeout
  end

  test "a timed-out request returns a failed response with the provider's Error" do
    provider = Provider::AlphaVantage.new("test_api_key")
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, "https://www.alphavantage.co/query")
      .with(query: hash_including("function" => "SYMBOL_SEARCH")).to_timeout
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::ConnectionFailed, errors.last
    assert_kind_of Net::OpenTimeout, errors.last.wrapped_exception
  end

  test "a read timeout is retried and returns a failed response with the provider's Error" do
    provider = Provider::AlphaVantage.new("test_api_key")
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, "https://www.alphavantage.co/query")
      .with(query: hash_including("function" => "SYMBOL_SEARCH")).to_raise(Net::ReadTimeout)
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::TimeoutError, errors.last
  end

  # ================================
  #        search_securities
  # ================================

  test "search_securities maps bestMatches, strips the exchange suffix and caches the currency" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    provider = alpha_vantage_provider

    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "SYMBOL_SEARCH", "keywords" => "CSPX"))
      .to_return(status: 200, body: {
        "bestMatches" => [
          {
            "1. symbol" => "CSPX.LON",
            "2. name" => "iShares Core S&P 500 UCITS ETF",
            "4. region" => "United Kingdom",
            "8. currency" => "GBP"
          }
        ]
      }.to_json)

    result = provider.search_securities("CSPX")

    assert result.success?
    security = result.data.first
    assert_equal "CSPX", security.symbol
    assert_equal "iShares Core S&P 500 UCITS ETF", security.name
    assert_equal "XLON", security.exchange_operating_mic
    assert_equal "GB", security.country_code
    assert_equal "GBP", security.currency
    assert_equal "GBP", store.read("alpha_vantage:currency:CSPX.LON")
  end

  test "search_securities fails when bestMatches is missing" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "SYMBOL_SEARCH"))
      .to_return(status: 200, body: {}.to_json)

    result = provider.search_securities("CSPX")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_equal "No data returned from search endpoint", result.error.message
  end

  # ================================
  #        fetch_security_info
  # ================================

  test "fetch_security_info maps OVERVIEW and lower-cases the asset type" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW", "symbol" => "AAPL"))
      .to_return(status: 200, body: {
        "Symbol" => "AAPL",
        "Name" => "Apple Inc",
        "AssetType" => "Common Stock",
        "Description" => "Technology company",
        "OfficialSite" => "https://www.apple.com"
      }.to_json)

    result = provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS")

    assert result.success?
    info = result.data
    assert_equal "AAPL", info.symbol
    assert_equal "Apple Inc", info.name
    assert_equal "common stock", info.kind
    assert_equal "Technology company", info.description
    assert_equal "https://www.apple.com", info.links
    assert_equal "XNYS", info.exchange_operating_mic
  end

  test "fetch_security_info fails when Name is blank" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW"))
      .to_return(status: 200, body: { "Symbol" => "AAPL", "Name" => "" }.to_json)

    result = provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/No metadata returned/, result.error.message)
  end

  # ================================
  #       fetch_security_prices
  # ================================

  test "fetch_security_prices keeps rows in the date window, skips non-positive prices and infers GBP" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including(
        "function" => "TIME_SERIES_DAILY",
        "symbol" => "CSPX.LON",
        "outputsize" => "compact"
      ))
      .to_return(status: 200, body: {
        "Time Series (Daily)" => {
          "2024-07-31" => { "4. close" => "99.00" },
          "2024-08-01" => { "4. close" => "100.50" },
          "2024-08-02" => { "4. close" => "0.00" },
          "2024-08-03" => { "4. close" => "101.50" }
        }
      }.to_json)

    result = provider.fetch_security_prices(
      symbol: "CSPX",
      exchange_operating_mic: "XLON",
      start_date: Date.new(2024, 8, 1),
      end_date: Date.new(2024, 8, 3)
    )

    assert result.success?
    assert_equal [ Date.new(2024, 8, 1), Date.new(2024, 8, 3) ], result.data.map(&:date)
    assert_equal [ "100.50", "101.50" ], result.data.map(&:price)
    assert_equal [ "GBP", "GBP" ], result.data.map(&:currency)
    assert_equal [ "CSPX", "CSPX" ], result.data.map(&:symbol)
  end

  test "fetch_security_prices fails when the time series is missing" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "TIME_SERIES_DAILY"))
      .to_return(status: 200, body: {}.to_json)

    result = provider.fetch_security_prices(
      symbol: "CSPX",
      exchange_operating_mic: "XLON",
      start_date: Date.new(2024, 8, 1),
      end_date: Date.new(2024, 8, 2)
    )

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/No time series data returned/, result.error.message)
  end

  # ================================
  #        fetch_security_price
  # ================================

  test "fetch_security_price returns the row for the exact date" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "TIME_SERIES_DAILY"))
      .to_return(status: 200, body: {
        "Time Series (Daily)" => {
          "2024-08-01" => { "4. close" => "100.50" },
          "2024-08-02" => { "4. close" => "101.50" }
        }
      }.to_json)

    result = provider.fetch_security_price(
      symbol: "CSPX",
      exchange_operating_mic: "XLON",
      date: Date.new(2024, 8, 2)
    )

    assert result.success?
    assert_equal Date.new(2024, 8, 2), result.data.date
    assert_equal "101.50", result.data.price
  end

  test "fetch_security_price fails when no row falls on the date" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "TIME_SERIES_DAILY"))
      .to_return(status: 200, body: {
        "Time Series (Daily)" => {
          "2024-08-01" => { "4. close" => "100.50" }
        }
      }.to_json)

    result = provider.fetch_security_price(
      symbol: "CSPX",
      exchange_operating_mic: "XLON",
      date: Date.new(2024, 8, 2)
    )

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/No prices found/, result.error.message)
  end

  # ================================
  #           Error mapping
  # ================================

  test "a Note body returns a failed response with RateLimitError" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "SYMBOL_SEARCH"))
      .to_return(status: 200, body: { "Note" => "Thank you for using Alpha Vantage" }.to_json)

    result = provider.search_securities("CSPX")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::RateLimitError, result.error
    assert_equal "Thank you for using Alpha Vantage", result.error.message
  end

  test "an Information body returns a failed response with RateLimitError" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "SYMBOL_SEARCH"))
      .to_return(status: 200, body: { "Information" => "Daily rate limit reached" }.to_json)

    result = provider.search_securities("CSPX")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::RateLimitError, result.error
    assert_equal "Daily rate limit reached", result.error.message
  end

  test "an Error Message body returns a failed response with Error" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "SYMBOL_SEARCH"))
      .to_return(status: 200, body: { "Error Message" => "Invalid API call" }.to_json)

    result = provider.search_securities("CSPX")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_equal "API error: Invalid API call", result.error.message
  end

  test "an HTTP 500 returns a failed response with Error" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "SYMBOL_SEARCH"))
      .to_return(status: 500, body: "Internal Server Error")

    result = provider.search_securities("CSPX")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
  end

  test "an HTTP 429 returns a failed response with RateLimitError" do
    provider = alpha_vantage_provider
    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "SYMBOL_SEARCH"))
      .to_return(status: 429, body: "Too Many Requests")

    result = provider.search_securities("CSPX")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::RateLimitError, result.error
  end

  private
    def alpha_vantage_provider
      provider = Provider::AlphaVantage.new("test_api_key")
      provider.stubs(:throttle_request)
      provider
    end
end
