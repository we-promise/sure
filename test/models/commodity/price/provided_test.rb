require "test_helper"

class Commodity::Price::ProvidedTest < ActiveSupport::TestCase
  setup do
    DebugLogEntry.stubs(:capture)
    travel_to Time.zone.local(2026, 10, 15, 18)
    @gold = Commodity.metal("XAU")
    @today = Date.new(2026, 10, 15)
    @yesterday = Date.new(2026, 10, 14)
    @yahoo = Provider::YahooFinance.new
    @gold_api = Provider::GoldApi.new
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(@yahoo)
    Provider::Registry.stubs(:get_provider).with(:gold_api).returns(@gold_api)
  end

  test "uses Yahoo futures for history and gold-api spot for today, without creating securities" do
    @yahoo.expects(:fetch_security_prices)
      .with(symbol: "GC=F", exchange_operating_mic: nil, start_date: @yesterday, end_date: @today)
      .returns(futures([ @yesterday, 4100 ], [ @today, 4190 ]))
    @gold_api.expects(:fetch_current_prices).with(symbols: [ "XAU" ]).returns(spot(@today, 4155.4))

    assert_no_difference [ "Security.count", "Holding.count", "Trade.count" ] do
      prices = Commodity::Price.fetch_provider_prices([ @gold ], start_date: @yesterday, end_date: @today).fetch("XAU")

      assert_equal [ [ @yesterday, "yahoo_futures", BigDecimal("4100") ], [ @today, "gold_api", BigDecimal("4155.4") ] ],
                   prices.map { |p| [ p.date, p.source, p.price ] }
    end
  end

  test "does not ask for spot prices when the range ends before today" do
    @yahoo.stubs(:fetch_security_prices).returns(futures([ @yesterday, 4100 ]))
    @gold_api.expects(:fetch_current_prices).never

    prices = Commodity::Price.fetch_provider_prices([ @gold ], start_date: @yesterday, end_date: @yesterday).fetch("XAU")

    assert_equal [ "yahoo_futures" ], prices.map(&:source)
  end

  test "falls back to futures when gold-api is unavailable" do
    @yahoo.stubs(:fetch_security_prices).returns(futures([ @today, 4190 ]))
    @gold_api.stubs(:fetch_current_prices).returns(Provider::Response.new(success?: false, data: nil, error: Provider::GoldApi::Error.new("down")))

    prices = Commodity::Price.fetch_provider_prices([ @gold ], start_date: @today, end_date: @today).fetch("XAU")

    assert_equal [ [ "yahoo_futures", BigDecimal("4190") ] ], prices.map { |p| [ p.source, p.price ] }
  end

  private
    def futures(*rows)
      Provider::Response.new(success?: true, error: nil, data: rows.map { |date, price|
        Provider::SecurityConcept::Price.new(symbol: "GC=F", date: date, price: BigDecimal(price.to_s), currency: "USD", exchange_operating_mic: nil)
      })
    end

    def spot(date, price)
      Provider::Response.new(success?: true, error: nil, data: [
        Provider::GoldApi::Price.new(symbol: "XAU", date: date, price: BigDecimal(price.to_s), currency: "USD")
      ])
    end
end
