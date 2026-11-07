require "test_helper"

# The ingestion tests build a `SecurityInfo` directly, so a wrong key name in
# `parsed.dig("ETF_Data", "Holdings")` would sail straight past them. These assert
# the mapping against a payload shaped like EODHD's own response, so the key names
# themselves are under test -- the same reason the classification fields have
# their own provider field test.
#
# The endpoint is the one `fetch_security_info` already calls for every security,
# so constituents cost no additional provider request.
class Provider::EtfConstituentsTest < ActiveSupport::TestCase
  test "EODHD reads fund holdings from the ETF_Data block" do
    body = {
      "General" => { "Name" => "Vanguard FTSE All-World", "Type" => "ETF" },
      "ETF_Data" => {
        "Holdings" => {
          "AAPL.US" => { "Code" => "AAPL", "Name" => "Apple Inc", "Assets_%" => 4.51 },
          "MSFT.US" => { "Code" => "MSFT", "Name" => "Microsoft Corp", "Assets_%" => 3.92 }
        }
      }
    }.to_json

    info = fetch(body)

    assert_equal 2, info.constituents.length
    apple = info.constituents.find { |c| c[:ticker] == "AAPL" }
    assert_equal "Apple Inc", apple[:name]
    assert_equal 4.51, apple[:weight].to_f
  end

  # Most securities are not funds, so this is the ordinary case rather than an
  # edge one: it must come back empty rather than raising.
  test "a payload with no ETF_Data yields no constituents" do
    body = { "General" => { "Name" => "Apple Inc", "Type" => "Common Stock" } }.to_json

    assert_nil fetch(body).constituents
  end

  test "a fund with an empty holdings block yields no constituents" do
    body = { "General" => { "Type" => "ETF" }, "ETF_Data" => { "Holdings" => {} } }.to_json

    assert_nil fetch(body).constituents
  end

  # The ticker EODHD keys the hash by carries its exchange suffix; `Code` is the
  # bare ticker. Keying on the hash key would store "AAPL.US", which matches
  # nothing in `securities`.
  test "the bare Code is stored, not the suffixed hash key" do
    body = {
      "General" => { "Type" => "ETF" },
      "ETF_Data" => { "Holdings" => { "AAPL.US" => { "Code" => "AAPL", "Assets_%" => 1 } } }
    }.to_json

    assert_equal [ "AAPL" ], fetch(body).constituents.map { |c| c[:ticker] }
  end

  # `SecurityInfo` has ten implementers and only EODHD builds `constituents:`;
  # a field without a default would break the other nine at construction.
  test "the original seven arguments still construct a SecurityInfo" do
    built = Provider::SecurityConcept::SecurityInfo.new(
      symbol: "AAPL", name: "Apple", links: nil, logo_url: nil,
      description: nil, kind: "Common Stock", exchange_operating_mic: "XNAS"
    )

    assert_nil built.constituents
    assert_nil built.sector
  end

  private
    def fetch(body)
      provider = Provider::Eodhd.new("test_api_key")
      provider.stubs(:enforce_daily_limit!)
      provider.stubs(:throttle_request)
      provider.stubs(:client).returns(client = mock)
      client.stubs(:get).returns(stub(body: body))

      provider.fetch_security_info(symbol: "VWRA", exchange_operating_mic: "XLON").data
    end
end
