require "test_helper"

class Provider::MfapiTest < ActiveSupport::TestCase
  include ProviderTestHelper

  test "client sets explicit open and read timeouts" do
    provider = Provider::Mfapi.new
    options = provider.send(:client).options

    assert_equal 5, options.open_timeout
    assert_equal 20, options.timeout
  end

  test "a timed-out request returns a failed response with the provider's Error" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, %r{\Ahttps://api\.mfapi\.in/mf/search}).to_timeout
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::ConnectionFailed, errors.last
    assert_kind_of Net::OpenTimeout, errors.last.wrapped_exception
  end

  test "a read timeout is retried and returns a failed response with the provider's Error" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, %r{\Ahttps://api\.mfapi\.in/mf/search}).to_raise(Net::ReadTimeout)
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::TimeoutError, errors.last
  end

  # ================================
  #        search_securities
  # ================================

  test "search_securities maps matches to Indian securities" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/search")
      .with(query: hash_including("q" => "axis"))
      .to_return(status: 200, body: [
        { "schemeCode" => 125497, "schemeName" => "Axis Bluechip Fund - Direct Plan" }
      ].to_json)

    result = provider.search_securities("axis")

    assert result.success?
    security = result.data.first
    assert_equal "125497", security.symbol
    assert_equal "Axis Bluechip Fund - Direct Plan", security.name
    assert_equal "XBOM", security.exchange_operating_mic
    assert_equal "IN", security.country_code
    assert_equal "INR", security.currency
  end

  test "search_securities fails when the body is not an array" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/search")
      .with(query: hash_including("q" => "axis"))
      .to_return(status: 200, body: { "foo" => "bar" }.to_json)

    result = provider.search_securities("axis")

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_equal "Unexpected response format from search endpoint", result.error.message
  end

  # ================================
  #        fetch_security_info
  # ================================

  test "fetch_security_info maps the latest meta and reports a mutual fund" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/125497/latest")
      .to_return(status: 200, body: {
        "meta" => {
          "scheme_name" => "Axis Bluechip Fund - Direct Plan",
          "fund_house" => "Axis Mutual Fund",
          "scheme_category" => "Equity Scheme"
        }
      }.to_json)

    result = provider.fetch_security_info(symbol: "125497", exchange_operating_mic: "XBOM")

    assert result.success?
    info = result.data
    assert_equal "125497", info.symbol
    assert_equal "Axis Bluechip Fund - Direct Plan", info.name
    assert_equal "Axis Mutual Fund - Equity Scheme", info.description
    assert_equal "mutual fund", info.kind
    assert_equal "XBOM", info.exchange_operating_mic
  end

  # ================================
  #       fetch_security_prices
  # ================================

  test "fetch_security_prices parses DD-MM-YYYY and skips invalid NAV rows" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/125497")
      .with(query: hash_including("startDate" => "2024-02-01", "endDate" => "2024-02-05"))
      .to_return(status: 200, body: {
        "data" => [
          { "date" => "01-02-2024", "nav" => "100.50" },
          { "date" => "02-02-2024", "nav" => "0" },
          { "date" => "03-02-2024", "nav" => nil },
          { "date" => "", "nav" => "50.00" },
          { "date" => "05-02-2024", "nav" => "101.50" }
        ]
      }.to_json)

    result = provider.fetch_security_prices(
      symbol: "125497",
      exchange_operating_mic: "XBOM",
      start_date: Date.new(2024, 2, 1),
      end_date: Date.new(2024, 2, 5)
    )

    assert result.success?
    assert_equal [ Date.new(2024, 2, 1), Date.new(2024, 2, 5) ], result.data.map(&:date)
    assert_equal [ 100.5, 101.5 ], result.data.map(&:price)
    assert_equal [ "INR", "INR" ], result.data.map(&:currency)
  end

  test "fetch_security_prices fails when data is missing" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/125497")
      .with(query: hash_including("startDate" => "2024-02-01", "endDate" => "2024-02-05"))
      .to_return(status: 200, body: {}.to_json)

    result = provider.fetch_security_prices(
      symbol: "125497",
      exchange_operating_mic: "XBOM",
      start_date: Date.new(2024, 2, 1),
      end_date: Date.new(2024, 2, 5)
    )

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_match(/No NAV data returned/, result.error.message)
  end

  # ================================
  #        fetch_security_price
  # ================================

  test "fetch_security_price uses a seven-day lookback and returns the nearest earlier NAV" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/125497")
      .with(query: hash_including("startDate" => "2024-01-31", "endDate" => "2024-02-07"))
      .to_return(status: 200, body: {
        "data" => [
          { "date" => "05-02-2024", "nav" => "100.50" },
          { "date" => "08-02-2024", "nav" => "102.50" }
        ]
      }.to_json)

    result = provider.fetch_security_price(
      symbol: "125497",
      exchange_operating_mic: "XBOM",
      date: Date.new(2024, 2, 7)
    )

    assert result.success?
    assert_equal Date.new(2024, 2, 5), result.data.date
    assert_equal 100.5, result.data.price
  end

  # ================================
  #           Error mapping
  # ================================

  test "an ERROR status body returns a failed response with Error" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/search")
      .with(query: hash_including("q" => "axis"))
      .to_return(status: 200, body: { "status" => "ERROR", "message" => "Invalid scheme" }.to_json)

    result = provider.search_securities("axis")

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_equal "API error: Invalid scheme", result.error.message
  end

  test "a FAIL status body returns a failed response with Error" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/search")
      .with(query: hash_including("q" => "axis"))
      .to_return(status: 200, body: { "status" => "FAIL" }.to_json)

    result = provider.search_securities("axis")

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_equal "API error: FAIL", result.error.message
  end

  test "an HTTP 500 returns a failed response with Error" do
    provider = mfapi_provider
    stub_request(:get, "https://api.mfapi.in/mf/search")
      .with(query: hash_including("q" => "axis"))
      .to_return(status: 500, body: "Internal Server Error")

    result = provider.search_securities("axis")

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
  end

  private
    def mfapi_provider
      provider = Provider::Mfapi.new
      provider.stubs(:throttle_request)
      provider
    end
end
