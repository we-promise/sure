require "test_helper"

class Provider::MetalPriceApiTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::MetalPriceApi.new("test-key")
  end

  test "parses USD-per-ounce timeframe rates" do
    stub_request(:get, %r{api.metalpriceapi.com/v1/timeframe})
      .with(headers: { "X-API-KEY" => "test-key" }, query: hash_including("base" => "USD", "currencies" => "XAU,XAG", "start_date" => "2026-04-22", "end_date" => "2026-04-23"))
      .to_return(status: 200, body: {
        success: true, base: "USD",
        rates: {
          "2026-04-22" => { "XAU" => 0.00056078, "USDXAU" => 1783.2305, "XAG" => 0.03825732, "USDXAG" => 26.1387886 },
          "2026-04-23" => { "XAU" => 0.0005628, "USDXAU" => 1776.830135, "XAG" => 0.03846131, "USDXAG" => 26.00015444 }
        }
      }.to_json)

    response = @provider.fetch_commodity_prices(symbols: %w[XAU XAG], start_date: Date.new(2026, 4, 22), end_date: Date.new(2026, 4, 23))

    assert response.success?
    gold = response.data.select { |p| p.symbol == "XAU" }.sort_by(&:date)
    assert_equal [ BigDecimal("1783.2305"), BigDecimal("1776.830135") ], gold.map(&:price)
    assert_equal %w[USD], response.data.map(&:currency).uniq
    assert_equal 4, response.data.size
  end

  test "splits ranges longer than 365 days into separate requests" do
    request = stub_request(:get, %r{api.metalpriceapi.com/v1/timeframe})
      .to_return(status: 200, body: { success: true, rates: {} }.to_json)

    @provider.fetch_commodity_prices(symbols: %w[XAU], start_date: Date.new(2025, 1, 1), end_date: Date.new(2026, 3, 1))

    assert_requested request, times: 2
  end

  test "returns an error response for API errors" do
    stub_request(:get, %r{api.metalpriceapi.com/v1/timeframe})
      .to_return(status: 200, body: { success: false, error: { code: 104, info: "Monthly usage limit reached" } }.to_json)

    response = @provider.fetch_commodity_prices(symbols: %w[XAU], start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 2))

    assert_not response.success?
    assert_match "usage limit", response.error.message
  end
end
