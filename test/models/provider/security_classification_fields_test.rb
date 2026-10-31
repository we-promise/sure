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
end
