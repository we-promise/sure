require "test_helper"

# The three providers carry sector and industry under different keys, and the
# ingestion tests cannot catch a wrong one: they build a `SecurityInfo` directly,
# so a typo in `general.dig("Sector")` would sail past them.
#
# These assert the mapping against a payload shaped like the provider's own
# response, so the key names themselves are under test.
class Provider::SecurityClassificationFieldsTest < ActiveSupport::TestCase
  # EODHD: nested under `General`, title case.
  test "EODHD reads Sector and Industry from the General block" do
    body = {
      "General" => {
        "Name" => "Apple Inc",
        "Type" => "Common Stock",
        "Sector" => "Technology",
        "Industry" => "Consumer Electronics"
      }
    }.to_json

    provider = Provider::Eodhd.new("test_api_key")
    provider.stubs(:enforce_daily_limit!)
    provider.stubs(:throttle_request)
    provider.stubs(:client).returns(client = mock)
    client.stubs(:get).returns(stub(body: body))

    info = provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS").data

    assert_equal "Technology", info.sector
    assert_equal "Consumer Electronics", info.industry
  end

  # Alpha Vantage: flat OVERVIEW payload, title case.
  test "Alpha Vantage reads Sector and Industry from the OVERVIEW payload" do
    body = {
      "Symbol" => "AAPL",
      "Name" => "Apple Inc",
      "AssetType" => "Common Stock",
      "Sector" => "TECHNOLOGY",
      "Industry" => "ELECTRONIC COMPUTERS"
    }.to_json

    provider = Provider::AlphaVantage.new("test_api_key")
    provider.stubs(:throttle_request)
    provider.stubs(:client).returns(client = mock)
    client.stubs(:get).returns(stub(body: body))

    info = provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS").data

    assert_equal "TECHNOLOGY", info.sector
    assert_equal "ELECTRONIC COMPUTERS", info.industry
  end

  # Yahoo: nested under `assetProfile`, lower case — the one most likely to be
  # got wrong by copying EODHD's casing.
  test "Yahoo reads sector and industry from assetProfile" do
    body = {
      "quoteSummary" => {
        "result" => [ {
          "assetProfile" => { "sector" => "Technology", "industry" => "Consumer Electronics" },
          "price" => { "longName" => "Apple Inc" },
          "quoteType" => { "quoteType" => "EQUITY" }
        } ],
        "error" => nil
      }
    }.to_json

    provider = Provider::YahooFinance.new
    provider.stubs(:throttle_request)
    provider.stubs(:fetch_cookie_and_crumb).returns([ "cookie", "crumb" ])
    provider.stubs(:authenticated_client).returns(client = mock)
    client.stubs(:get).returns(stub(body: body))

    info = provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS").data

    assert_equal "Technology", info.sector
    assert_equal "Consumer Electronics", info.industry
  end

  test "EODHD reads the issuer country from General.CountryISO" do
    info = eodhd_info("General" => { "Name" => "Alibaba Group Holding Ltd", "Type" => "Common Stock", "CountryISO" => "CN" })

    assert_equal "CN", info.issuer_country_code
    assert_nil info.fund_weights
  end

  # ETF_Data keys each breakdown by label, with the percentage as a string.
  test "EODHD reads an ETF's asset classes, regions and sectors from ETF_Data" do
    info = eodhd_info(
      "General" => { "Name" => "Vanguard FTSE All-World", "Type" => "ETF", "CountryISO" => "DE" },
      "ETF_Data" => {
        "Domicile" => "Ireland",
        "Asset_Allocation" => {
          "Cash" => { "Long_%" => "0.3", "Short_%" => "0", "Net_Assets_%" => "0.3" },
          "NotClassified" => { "Net_Assets_%" => "0.1" },
          "Stock non-US" => { "Net_Assets_%" => "37.4" },
          "Other" => { "Net_Assets_%" => "0" },
          "Stock US" => { "Net_Assets_%" => "62.2" },
          "Bond" => { "Net_Assets_%" => "0" }
        },
        "World_Regions" => {
          "North America" => { "Equity_%" => "64.1", "Relative_to_Category" => "60.0" },
          "United Kingdom" => { "Equity_%" => "3.2" },
          "Europe Developed" => { "Equity_%" => "12.0" },
          "Japan" => { "Equity_%" => "5.5" },
          "Asia Emerging" => { "Equity_%" => "9.0" },
          "Latin America" => { "Equity_%" => "1.0" },
          "Africa/Middle East" => { "Equity_%" => "1.2" }
        },
        "Sector_Weights" => {
          "Technology" => { "Equity_%" => "26.0" },
          "Financial Services" => { "Equity_%" => "16.5" }
        }
      }
    )

    weights = info.fund_weights
    assert_in_delta 99.6, weights[:asset_class]["equity"]
    assert_in_delta 0.3, weights[:asset_class]["liquidity"]
    assert_in_delta 0.0, weights[:asset_class]["fixed_income"]
    assert_in_delta 64.1, weights[:region]["north_america"]
    assert_in_delta 15.2, weights[:region]["europe"]
    assert_in_delta 14.5, weights[:region]["asia_pacific"]
    assert_in_delta 26.0, weights[:sector]["Technology"]
  end

  # MutualFund_Data groups regions and sectors into lists of rows.
  test "EODHD reads a fund's asset classes, regions and sectors from MutualFund_Data" do
    info = eodhd_info(
      "General" => { "Name" => "Some Index Fund", "Type" => "FUND" },
      "MutualFund_Data" => {
        "Asset_Allocation" => {
          "Cash" => { "Type" => "Cash", "Net_%" => "1.0" },
          "US Stocks" => { "Type" => "US Stocks", "Net_%" => "97.0" },
          "Non US Stocks" => { "Type" => "Non US Stocks", "Net_%" => "2.0" },
          "Bonds" => { "Type" => "Bonds", "Net_%" => "0" }
        },
        "World_Regions" => {
          "Americas" => [ { "Name" => "North America", "Stocks_%" => "98.5" }, { "Name" => "Latin America", "Stocks_%" => "0.5" } ],
          "Greater Europe" => [ { "Name" => "United Kingdom", "Stocks_%" => "1.0" } ]
        },
        "Sector_Weights" => {
          "Cyclical" => [ { "Type" => "Basic Materials", "Amount_%" => "2.0" } ],
          "Sensitive" => [ { "Type" => "Technology", "Amount_%" => "30.0" } ]
        }
      }
    )

    weights = info.fund_weights
    assert_in_delta 99.0, weights[:asset_class]["equity"]
    assert_in_delta 98.5, weights[:region]["north_america"]
    assert_in_delta 1.0, weights[:region]["europe"]
    assert_in_delta 30.0, weights[:sector]["Technology"]
  end

  private
    def eodhd_info(payload)
      provider = Provider::Eodhd.new("test_api_key")
      provider.stubs(:enforce_daily_limit!)
      provider.stubs(:throttle_request)
      provider.stubs(:client).returns(client = mock)
      client.stubs(:get).returns(stub(body: payload.to_json))

      provider.fetch_security_info(symbol: "X", exchange_operating_mic: "XNAS").data
    end
end
