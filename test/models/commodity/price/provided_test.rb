require "test_helper"

class Commodity::Price::ProvidedTest < ActiveSupport::TestCase
  setup do
    DebugLogEntry.stubs(:capture)
    @gold = Commodity.metal("XAU")
    @date = Date.new(2026, 10, 1)
  end

  test "falls back to Yahoo front-month futures without creating securities" do
    Provider::Registry.stubs(:get_provider).with(:metal_price_api).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(yahoo = Provider::YahooFinance.new)
    yahoo.expects(:fetch_security_prices)
      .with(symbol: "GC=F", exchange_operating_mic: nil, start_date: @date, end_date: @date)
      .returns(Provider::Response.new(success?: true, error: nil, data: [
        Provider::SecurityConcept::Price.new(symbol: "GC=F", date: @date, price: 2650.4, currency: "USD", exchange_operating_mic: nil)
      ]))

    assert_no_difference [ "Security.count", "Holding.count", "Trade.count" ] do
      prices = Commodity::Price.fetch_provider_prices([ @gold ], start_date: @date, end_date: @date)

      price = prices.fetch("XAU").sole
      assert_equal [ "yahoo_futures", "USD", @date ], [ price.source, price.currency, price.date ]
    end
  end

  test "uses the spot provider when an API key is configured" do
    spot = Provider::MetalPriceApi.new("key")
    Provider::Registry.stubs(:get_provider).with(:metal_price_api).returns(spot)
    Provider::Registry.expects(:get_provider).with(:yahoo_finance).never
    spot.expects(:fetch_commodity_prices).with(symbols: [ "XAU" ], start_date: @date, end_date: @date)
      .returns(Provider::Response.new(success?: true, error: nil, data: [
        Provider::MetalPriceApi::Price.new(symbol: "XAU", date: @date, price: BigDecimal("2648.1"), currency: "USD")
      ]))

    price = Commodity::Price.fetch_provider_prices([ @gold ], start_date: @date, end_date: @date).fetch("XAU").sole

    assert_equal [ "metal_price_api", BigDecimal("2648.1") ], [ price.source, price.price ]
  end

  test "falls back to futures when the spot provider fails" do
    spot = Provider::MetalPriceApi.new("key")
    yahoo = Provider::YahooFinance.new
    Provider::Registry.stubs(:get_provider).with(:metal_price_api).returns(spot)
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(yahoo)
    spot.stubs(:fetch_commodity_prices).returns(Provider::Response.new(success?: false, data: nil, error: Provider::MetalPriceApi::Error.new("limit")))
    yahoo.expects(:fetch_security_prices).returns(Provider::Response.new(success?: true, error: nil, data: []))

    assert_equal({ "XAU" => [] }, Commodity::Price.fetch_provider_prices([ @gold ], start_date: @date, end_date: @date))
  end
end
