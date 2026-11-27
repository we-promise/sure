require "test_helper"

class Provider::ScalableCapitalMarketDataTest < ActiveSupport::TestCase
  ISIN = "IE00B4L5Y983"

  setup do
    @family = families(:dylan_family)
    @item = @family.scalable_capital_items.create!(portfolio_id: "portfolio", broker_account_id: "person")
    @client = mock
    @client.stubs(:identity).returns("person")
    @provider = Provider::ScalableCapitalMarketData.new(@item, client: @client)
    travel_to Time.utc(2026, 11, 24, 18)
  end

  test "registers the verified portfolio for securities but never for exchange rates" do
    ScalableCapitalItem.stubs(:configured_family_id).returns(@family.id)
    registry = Provider::Registry.for_concept(:securities)
    assert_instance_of Provider::ScalableCapitalMarketData, registry.get_provider(:scalable_capital_market_data)
    assert_not_includes Provider::Registry.for_concept(:exchange_rates).provider_keys, :scalable_capital_market_data

    @item.update!(broker_account_id: nil)
    assert_nil registry.get_provider(:scalable_capital_market_data)
  end

  test "uses a search result's real ISIN without inventing its ticker or exchange" do
    @client.expects(:search_securities).with("portfolio", "Core MSCI World").returns(broker_result(
      "items" => [ { "isin" => ISIN, "name" => "Example ETF", "quote_currency" => "EUR", "quote_venue" => "SEIX" } ]
    ))

    response = @provider.search_securities("Core MSCI World")

    assert_predicate response, :success?
    security = response.data.sole
    assert_equal [ ISIN, ISIN, "EUR" ], [ security.symbol, security.isin, security.currency ]
    assert_nil security.exchange_operating_mic
  end

  test "opens no market data command when the CLI session belongs to another person" do
    @client.expects(:identity).returns("other-person")
    @client.expects(:security_candlesticks).never

    response = @provider.fetch_security_prices(symbol: ISIN, exchange_operating_mic: nil, start_date: Date.current - 3, end_date: Date.current)

    refute_predicate response, :success?
    assert_match(/original Scalable account/, response.error.message)
  end

  test "uses a current quote only when it matches the requested security and date" do
    data = { "isin" => ISIN, "quote_is_outdated" => false, "quote_timestamp_utc" => 1.minute.ago.iso8601,
             "quote_mid_price" => "84.12345678", "quote_currency" => "EUR" }
    @client.expects(:security_quote).with("portfolio", ISIN).returns(broker_result(data), broker_result(data.merge("quote_is_outdated" => true))).twice

    response = @provider.fetch_security_price(symbol: ISIN, exchange_operating_mic: nil, date: Date.current)
    assert_predicate response, :success?
    assert_equal 84.12345678.to_d, response.data.price
    missing = @provider.fetch_security_price(symbol: ISIN, exchange_operating_mic: nil, date: Date.current)
    refute_predicate missing, :success?
    assert_equal :no_price, missing.error.failure_code
  end

  test "missing quotes and historical dates are safe through the price cache" do
    security = Security.create!(ticker: ISIN, price_provider: Provider::ScalableCapitalMarketData::KEY)
    security.stubs(:price_data_provider).returns(@provider)
    security.prices.create!(date: Date.current, price: 10, currency: "EUR", provisional: true, carried_forward: true)
    @client.expects(:security_quote).with("portfolio", ISIN).returns(broker_result({ "isin" => ISIN, "quote_is_outdated" => true }))
    @client.expects(:security_candlesticks).with(ISIN, "one_month").returns(candlesticks([]))

    assert_no_difference -> { security.prices.count } do
      assert_nil security.find_or_fetch_price
      assert_nil security.find_or_fetch_price(date: Date.current - 1)
    end
    assert_predicate security.prices.sole, :carried_forward?
  end

  test "a live quote replaces a carried-forward price and remains provisional until a close arrives" do
    security = Security.create!(ticker: ISIN, price_provider: Provider::ScalableCapitalMarketData::KEY)
    security.stubs(:price_data_provider).returns(@provider)
    price = security.prices.create!(date: Date.current, price: 10, currency: "EUR", provisional: true, carried_forward: true)
    @client.expects(:security_quote).with("portfolio", ISIN).returns(broker_result(
      "isin" => ISIN, "quote_is_outdated" => false, "quote_timestamp_utc" => 1.minute.ago.iso8601,
      "quote_mid_price" => "84", "quote_currency" => "EUR"
    ))

    assert_equal 84.to_d, security.find_or_fetch_price.price
    assert_equal 84.to_d, price.reload.price
    assert_predicate price, :provisional?
    refute_predicate price, :carried_forward?
  end

  test "health checks use a recent Scalable close on a non-trading day" do
    security = Security.create!(ticker: ISIN, price_provider: Provider::ScalableCapitalMarketData::KEY, failed_fetch_count: 5)
    security.stubs(:price_data_provider).returns(@provider)
    travel_to Time.utc(2026, 11, 29, 12)
    @client.expects(:security_quote).never
    @client.expects(:security_candlesticks).with(ISIN, "one_month").returns(candlesticks([
      candle("2026-11-27T08:00:00Z", "2026-11-27T17:00:00Z", "85.12")
    ]))

    Security::HealthChecker.new(security).run_check

    refute_predicate security.reload, :offline?
    assert_equal 0, security.failed_fetch_count
    assert_empty security.prices
  end

  test "uses the last completed candle per Berlin date and skips multi-day bars" do
    @client.expects(:security_candlesticks).with(ISIN, "one_month").returns({
      "isin" => ISIN, "source" => "consolidated", "currency" => "EUR",
      "candlesticks" => [
        candle("2026-11-22T23:00:00Z", "2026-11-23T22:59:59Z", "85.12"),
        candle("2026-11-23T08:00:00Z", "2026-11-23T09:00:00Z", "80"),
        candle("2026-11-24T08:00:00Z", "2026-11-24T20:00:00Z", "91"),
        candle("2026-11-22T08:00:00Z", "2026-11-24T09:00:00Z", "99")
      ]
    })

    response = @provider.fetch_security_prices(symbol: ISIN, exchange_operating_mic: nil, start_date: Date.current - 2, end_date: Date.current)

    assert_predicate response, :success?
    assert_equal Date.new(2026, 11, 23), response.data.sole.date
    assert_equal 85.12.to_d, response.data.sole.price
  end

  test "does not use Scalable as the default for a ticker without an ISIN" do
    yahoo = Provider::YahooFinance.new
    Security.stubs(:providers).returns([ @provider, yahoo ])

    assert_equal yahoo, Security.new(ticker: "AAPL", exchange_operating_mic: "XNAS").price_data_provider
    assert_equal @provider, Security.new(ticker: ISIN).price_data_provider
  end

  private

    def broker_result(result)
      { "account_id" => "person", "portfolio_id" => "portfolio", "result" => result }
    end

    def candlesticks(rows)
      { "isin" => ISIN, "source" => "consolidated", "currency" => "EUR", "candlesticks" => rows }
    end

    def candle(start, finish, close)
      { "start_time_utc" => start, "end_time_utc" => finish, "close" => close }
    end
end
