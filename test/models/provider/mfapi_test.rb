require "test_helper"

class Provider::MfapiTest < ActiveSupport::TestCase
  BASE_URL = "https://api.mfapi.in".freeze

  setup do
    @provider = Provider::Mfapi.new
    @provider.stubs(:sleep)
  end

  test "search_securities maps schemes to Indian mutual funds" do
    stub_mfapi("/mf/search", [
      { "schemeCode" => 125497, "schemeName" => "SBI Small Cap Fund - Direct Plan - Growth" },
      { "schemeCode" => 120503, "schemeName" => "Axis Bluechip Fund - Direct Plan - Growth" }
    ], query: { "q" => "small cap" })

    result = @provider.search_securities("small cap")

    assert result.success?
    first, second = result.data
    assert_equal [ "125497", "SBI Small Cap Fund - Direct Plan - Growth", "XBOM", "IN", "INR" ],
                 [ first.symbol, first.name, first.exchange_operating_mic, first.country_code, first.currency ]
    assert_equal "120503", second.symbol
  end

  test "search_securities returns at most 25 matches" do
    stub_mfapi("/mf/search", Array.new(30) { |i| { "schemeCode" => i + 1, "schemeName" => "Fund #{i + 1}" } }, query: { "q" => "fund" })

    assert_equal 25, @provider.search_securities("fund").data.size
  end

  test "search_securities fails on a body that is not a list" do
    stub_mfapi("/mf/search", { "unexpected" => true }, query: { "q" => "x" })

    result = @provider.search_securities("x")

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_match(/Unexpected response format from search endpoint/, result.error.message)
  end

  test "an error status body is a provider error" do
    stub_mfapi("/mf/search", { "status" => "ERROR", "message" => "Scheme not found" }, query: { "q" => "x" })

    result = @provider.search_securities("x")

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_match(/\AAPI error: Scheme not found/, result.error.message)
  end

  test "fetch_security_info maps the latest NAV metadata" do
    stub_mfapi("/mf/125497/latest", {
      "meta" => { "scheme_name" => "SBI Small Cap Fund", "fund_house" => "SBI Mutual Fund", "scheme_category" => "Equity Scheme - Small Cap Fund" },
      "data" => [ { "date" => "02-02-2024", "nav" => "150.1" } ]
    })

    result = @provider.fetch_security_info(symbol: "125497", exchange_operating_mic: "XBOM")

    assert result.success?
    info = result.data
    assert_equal [ "125497", "SBI Small Cap Fund", "SBI Mutual Fund - Equity Scheme - Small Cap Fund", "mutual fund", "XBOM" ],
                 [ info.symbol, info.name, info.description, info.kind, info.exchange_operating_mic ]
  end

  test "fetch_security_prices parses DD-MM-YYYY dates and skips empty NAVs" do
    stub_mfapi("/mf/125497", { "data" => [
      { "date" => "01-02-2024", "nav" => "150.10" },
      { "date" => "31-01-2024", "nav" => "0.00000" },
      { "date" => "30-01-2024", "nav" => nil },
      { "date" => "29-01-2024", "nav" => "148.25" }
    ] }, query: { "startDate" => "2024-01-29", "endDate" => "2024-02-01" })

    result = @provider.fetch_security_prices(symbol: "125497", exchange_operating_mic: "XBOM", start_date: Date.new(2024, 1, 29), end_date: Date.new(2024, 2, 1))

    assert result.success?
    # "01-02-2024" is 1 February: a %m-%d-%Y parse would give 2 January
    assert_equal [ Date.new(2024, 2, 1), Date.new(2024, 1, 29) ], result.data.map(&:date)
    assert_equal [ 150.1, 148.25 ], result.data.map(&:price)
    assert_equal [ "INR" ], result.data.map(&:currency).uniq
  end

  test "fetch_security_prices fails when the response has no data list" do
    stub_mfapi("/mf/125497", { "meta" => {} }, query: { "startDate" => "2024-02-01", "endDate" => "2024-02-01" })

    result = @provider.fetch_security_prices(symbol: "125497", exchange_operating_mic: "XBOM", start_date: Date.new(2024, 2, 1), end_date: Date.new(2024, 2, 1))

    assert_not result.success?
    # with_provider_response maps every raised error, subclasses included, to the plain Error
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_match(/No NAV data returned for scheme 125497/, result.error.message)
  end

  test "fetch_security_price falls back to the nearest earlier NAV" do
    stub_mfapi("/mf/125497", { "data" => [
      { "date" => "08-02-2024", "nav" => "152.00" },
      { "date" => "05-02-2024", "nav" => "151.00" }
    ] }, query: { "startDate" => "2024-01-31", "endDate" => "2024-02-07" })

    result = @provider.fetch_security_price(symbol: "125497", exchange_operating_mic: "XBOM", date: Date.new(2024, 2, 7))

    assert result.success?
    assert_equal Date.new(2024, 2, 5), result.data.date
    assert_equal 151.0, result.data.price
  end

  test "fetch_security_price fails when no NAV falls in the lookback window" do
    stub_mfapi("/mf/125497", { "data" => [] }, query: { "startDate" => "2024-01-31", "endDate" => "2024-02-07" })

    result = @provider.fetch_security_price(symbol: "125497", exchange_operating_mic: "XBOM", date: Date.new(2024, 2, 7))

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
    assert_match(/No NAV found for scheme 125497 on or before 2024-02-07/, result.error.message)
  end

  test "an HTTP 500 is a plain provider error and an HTTP 429 is a rate-limit error" do
    stub_request(:get, "#{BASE_URL}/mf/125497/latest").to_return(status: 500, body: "")
    server_error = @provider.fetch_security_info(symbol: "125497", exchange_operating_mic: "XBOM")

    assert_not server_error.success?
    assert_instance_of Provider::Mfapi::Error, server_error.error

    stub_request(:get, "#{BASE_URL}/mf/125497/latest").to_return(status: 429, body: "")
    too_many = @provider.fetch_security_info(symbol: "125497", exchange_operating_mic: "XBOM")

    assert_not too_many.success?
    assert_instance_of Provider::Mfapi::RateLimitError, too_many.error
  end

  private
    def stub_mfapi(path, body, query: nil)
      stub = stub_request(:get, "#{BASE_URL}#{path}")
      stub = stub.with(query: query) if query
      stub.to_return(status: 200, body: body.to_json)
    end
end
