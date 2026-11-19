require "test_helper"

class Provider::AlphaVantageTest < ActiveSupport::TestCase
  OVERVIEW_URL = "https://www.alphavantage.co/query".freeze

  setup do
    @provider = Provider::AlphaVantage.new("test_api_key")
    @provider.stubs(:sleep)
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

  test "search_securities maps matches, strips the exchange suffix and caches the currency" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    stub_av("SYMBOL_SEARCH", { "bestMatches" => [
      { "1. symbol" => "CSPX.LON", "2. name" => "iShares Core S&P 500", "4. region" => "United Kingdom", "8. currency" => "USD" },
      { "1. symbol" => "AAPL", "2. name" => "Apple Inc", "4. region" => "United States", "8. currency" => "USD" }
    ] })

    result = @provider.search_securities("S&P")

    assert result.success?
    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "SYMBOL_SEARCH", "keywords" => "S&P")
    london, apple = result.data
    assert_equal [ "CSPX", "XLON", "GB", "USD" ], [ london.symbol, london.exchange_operating_mic, london.country_code, london.currency ]
    assert_equal [ "AAPL", nil, "US" ], [ apple.symbol, apple.exchange_operating_mic, apple.country_code ]
    # The cache key keeps the suffix, which is how fetch_security_prices looks it up
    assert_equal "USD", store.read("alpha_vantage:currency:CSPX.LON")
  end

  test "search_securities fails when the response has no bestMatches" do
    stub_av("SYMBOL_SEARCH", {})

    result = @provider.search_securities("AAPL")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/No data returned from search endpoint/, result.error.message)
  end

  test "fetch_security_info maps the overview and lower-cases the asset type" do
    stub_av("OVERVIEW", { "Symbol" => "AAPL", "Name" => "Apple Inc", "Description" => "Makes phones", "OfficialSite" => "https://apple.com", "AssetType" => "Common Stock" })

    result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS")

    assert result.success?
    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW", "symbol" => "AAPL")
    info = result.data
    assert_equal [ "AAPL", "Apple Inc", "Makes phones", "https://apple.com", "common stock", "XNAS" ],
                 [ info.symbol, info.name, info.description, info.links, info.kind, info.exchange_operating_mic ]
  end

  test "fetch_security_info requests the suffixed symbol for a non-US exchange" do
    stub_av("OVERVIEW", { "Symbol" => "CSPX.LON", "Name" => "iShares Core S&P 500" })

    assert @provider.fetch_security_info(symbol: "CSPX", exchange_operating_mic: "XLON").success?

    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW", "symbol" => "CSPX.LON")
  end

  test "fetch_security_info fails when the overview has no name" do
    stub_av("OVERVIEW", { "Symbol" => "AAPL", "Name" => "" })

    result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/No metadata returned for symbol AAPL/, result.error.message)
  end

  test "fetch_security_prices keeps rows inside the window and skips non-positive closes" do
    stub_av("TIME_SERIES_DAILY", { "Time Series (Daily)" => {
      "2024-02-02" => { "4. close" => "190.50" },
      "2024-02-01" => { "4. close" => "0.0000" },
      "2024-01-31" => { "4. close" => "188.00" },
      "2024-01-30" => { "4. close" => "187.00" }
    } })

    result = @provider.fetch_security_prices(symbol: "AAPL", exchange_operating_mic: "XNAS", start_date: Date.new(2024, 1, 31), end_date: Date.new(2024, 2, 2))

    assert result.success?
    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "TIME_SERIES_DAILY", "outputsize" => "compact")
    assert_equal [ Date.new(2024, 2, 2), Date.new(2024, 1, 31) ], result.data.map(&:date)
    assert_equal [ 190.5, 188.0 ], result.data.map { |price| price.price.to_f }
    assert_equal [ "USD" ], result.data.map(&:currency).uniq
  end

  test "fetch_security_prices infers the currency from the exchange suffix" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    stub_av("TIME_SERIES_DAILY", { "Time Series (Daily)" => { "2024-02-02" => { "4. close" => "500.10" } } })

    result = @provider.fetch_security_prices(symbol: "CSPX", exchange_operating_mic: "XLON", start_date: Date.new(2024, 2, 2), end_date: Date.new(2024, 2, 2))

    assert_requested :get, OVERVIEW_URL, query: hash_including("symbol" => "CSPX.LON")
    assert_equal [ "GBP" ], result.data.map(&:currency)
  end

  test "fetch_security_prices fails when the response has no time series" do
    stub_av("TIME_SERIES_DAILY", {})

    result = @provider.fetch_security_prices(symbol: "AAPL", exchange_operating_mic: "XNAS", start_date: Date.new(2024, 2, 2), end_date: Date.new(2024, 2, 2))

    assert_not result.success?
    # with_provider_response maps every raised error, subclasses included, to the plain Error
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/No time series data returned for symbol AAPL/, result.error.message)
  end

  test "fetch_security_price returns the row for the requested day" do
    stub_av("TIME_SERIES_DAILY", { "Time Series (Daily)" => {
      "2024-02-02" => { "4. close" => "190.50" },
      "2024-02-01" => { "4. close" => "189.00" }
    } })

    result = @provider.fetch_security_price(symbol: "AAPL", exchange_operating_mic: "XNAS", date: Date.new(2024, 2, 1))

    assert result.success?
    assert_equal Date.new(2024, 2, 1), result.data.date
    assert_equal 189.0, result.data.price.to_f
  end

  test "fetch_security_price fails when the day has no row" do
    stub_av("TIME_SERIES_DAILY", { "Time Series (Daily)" => { "2024-02-02" => { "4. close" => "190.50" } } })

    result = @provider.fetch_security_price(symbol: "AAPL", exchange_operating_mic: "XNAS", date: Date.new(2024, 2, 1))

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/No prices found for security AAPL on date 2024-02-01/, result.error.message)
  end

  test "a Note or Information body is a rate-limit error" do
    { "Note" => "Thank you for using Alpha Vantage! Call frequency exceeded.",
      "Information" => "The daily request limit has been reached." }.each do |key, message|
      stub_av("OVERVIEW", { key => message })

      result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS")

      assert_not result.success?, key
      assert_instance_of Provider::AlphaVantage::RateLimitError, result.error, key
      assert_equal message, result.error.message
    end
  end

  test "an Error Message body is a plain provider error" do
    stub_av("OVERVIEW", { "Error Message" => "Invalid API call." })

    result = @provider.fetch_security_info(symbol: "NOPE", exchange_operating_mic: "XNAS")

    assert_not result.success?
    assert_instance_of Provider::AlphaVantage::Error, result.error
    assert_match(/\AAPI error: Invalid API call/, result.error.message)
  end

  test "an HTTP 500 is a plain provider error and an HTTP 429 is a rate-limit error" do
    stub_request(:get, OVERVIEW_URL).with(query: hash_including("function" => "OVERVIEW")).to_return(status: 500, body: "")
    server_error = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS")

    assert_not server_error.success?
    assert_instance_of Provider::AlphaVantage::Error, server_error.error

    stub_request(:get, OVERVIEW_URL).with(query: hash_including("function" => "OVERVIEW")).to_return(status: 429, body: "")
    too_many = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS")

    assert_not too_many.success?
    assert_instance_of Provider::AlphaVantage::RateLimitError, too_many.error
  end

  private
    def stub_av(function, body)
      stub_request(:get, OVERVIEW_URL)
        .with(query: hash_including("function" => function))
        .to_return(status: 200, body: body.to_json)
    end
end
