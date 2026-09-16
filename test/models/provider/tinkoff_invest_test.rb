require "test_helper"

class Provider::TinkoffInvestTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::TinkoffInvest.new("test-token")
    @provider.stubs(:throttle_request)
    Rails.cache.clear
  end

  # ----- search -----

  test "search_securities maps a share to a stock with MOEX MIC" do
    stub_find("SBER", [ instrument_short(ticker: "SBER", name: "Sberbank", type: "share", class_code: "TQBR", currency: "rub", country: "RU") ])

    response = @provider.search_securities("SBER")

    assert response.success?
    sec = response.data.first
    assert_equal "SBER", sec.symbol
    assert_equal "Sberbank", sec.name
    assert_equal "MISX", sec.exchange_operating_mic
    assert_equal "RU", sec.country_code
    assert_equal "RUB", sec.currency
    assert_nil sec.logo_url, "search results carry no brand; logos come from fetch_security_info"
  end

  test "search_securities skips unsupported instrument kinds (futures, currency)" do
    stub_find("X", [
      instrument_short(ticker: "FUT", name: "Future", type: "futures", class_code: "SPBFUT"),
      instrument_short(ticker: "USD000UTSTOM", name: "Dollar", type: "currency", class_code: "CETS")
    ])

    response = @provider.search_securities("X")

    assert_empty response.data
  end

  # ----- info / logo -----

  test "fetch_security_info builds the CDN logo url from brand.logoName" do
    stub_find("SBER", [ instrument_short(ticker: "SBER", type: "share", class_code: "TQBR", uid: "uid-sber") ])
    stub_instrument_by("uid-sber", instrument_full(name: "Sberbank", logo_name: "SBER.png", exchange: "moex_mrng_evng_e_wknd_dlr"))

    response = @provider.fetch_security_info(symbol: "SBER", exchange_operating_mic: "MISX")

    assert response.success?
    assert_equal "Sberbank", response.data.name
    assert_equal "https://invest-brands.cdn-tinkoff.ru/SBERx160.png", response.data.logo_url
    assert_equal "MISX", response.data.exchange_operating_mic
    assert_equal "stock", response.data.kind
  end

  test "fetch_security_info returns a nil logo when brand is absent" do
    stub_find("XXX", [ instrument_short(ticker: "XXX", type: "share", class_code: "TQBR", uid: "uid-x") ])
    stub_instrument_by("uid-x", instrument_full(name: "No Brand", logo_name: nil))

    response = @provider.fetch_security_info(symbol: "XXX", exchange_operating_mic: nil)

    assert_nil response.data.logo_url
  end

  # ----- prices -----

  test "fetch_security_prices parses daily candle closes and appends the live last price" do
    travel_to Date.new(2026, 6, 18) do
      stub_find("SBER", [ instrument_short(ticker: "SBER", type: "share", class_code: "TQBR", uid: "uid-sber", currency: "rub") ])
      @provider.stubs(:post).with("MarketDataService", "GetCandles", anything).returns(
        "candles" => [
          candle("2026-06-16", units: 300, nano: 500_000_000),
          candle("2026-06-17", units: 305, nano: 0)
        ]
      )
      @provider.stubs(:post).with("MarketDataService", "GetLastPrices", anything).returns(
        "lastPrices" => [ { "price" => { "units" => "310", "nano" => 250_000_000 } } ]
      )

      response = @provider.fetch_security_prices(symbol: "SBER", exchange_operating_mic: "MISX", start_date: Date.new(2026, 6, 16), end_date: Date.new(2026, 6, 18))

      assert response.success?
      by_date = response.data.index_by(&:date)
      assert_equal BigDecimal("300.5"), by_date[Date.new(2026, 6, 16)].price
      assert_equal BigDecimal("305"), by_date[Date.new(2026, 6, 17)].price
      assert_equal BigDecimal("310.25"), by_date[Date.new(2026, 6, 18)].price, "today should use the live last price"
      assert_equal "RUB", by_date[Date.new(2026, 6, 16)].currency
    end
  end

  test "fetch_security_prices converts bond percent-of-par to money via nominal" do
    travel_to Date.new(2026, 6, 18) do
      stub_find("RU000A10AAQ4", [ instrument_short(ticker: "RU000A10AAQ4", isin: "RU000A10AAQ4", type: "bond", class_code: "TQCB", uid: "uid-bond", currency: "rub") ])
      stub_bond_by("uid-bond", { "nominal" => { "units" => "1000", "nano" => 0 } })
      @provider.stubs(:post).with("MarketDataService", "GetCandles", anything).returns(
        "candles" => [ candle("2026-06-17", units: 103, nano: 700_000_000) ] # 103.7% of par
      )
      @provider.stubs(:post).with("MarketDataService", "GetLastPrices", anything).returns("lastPrices" => [])

      response = @provider.fetch_security_prices(symbol: "RU000A10AAQ4", exchange_operating_mic: "MISX", start_date: Date.new(2026, 6, 17), end_date: Date.new(2026, 6, 17))

      price = response.data.first
      assert_equal BigDecimal("1037"), price.price, "103.7% of 1000 nominal = 1037"
    end
  end

  test "fetch_security_prices fails (no zero price) when a bond nominal is missing" do
    travel_to Date.new(2026, 6, 18) do
      stub_find("RU000A10AAQ4", [ instrument_short(ticker: "RU000A10AAQ4", type: "bond", class_code: "TQCB", uid: "uid-bond", currency: "rub") ])
      stub_bond_by("uid-bond", {}) # no nominal
      @provider.stubs(:post).with("MarketDataService", "GetCandles", anything).returns("candles" => [ candle("2026-06-17", units: 103, nano: 0) ])
      @provider.stubs(:post).with("MarketDataService", "GetLastPrices", anything).returns("lastPrices" => [])

      response = @provider.fetch_security_prices(symbol: "RU000A10AAQ4", exchange_operating_mic: "MISX", start_date: Date.new(2026, 6, 17), end_date: Date.new(2026, 6, 17))

      assert_not response.success?
      assert_kind_of Provider::TinkoffInvest::InvalidSecurityPriceError, response.error
    end
  end

  test "fetch_security_prices returns only the live price for an amortizing bond" do
    travel_to Date.new(2026, 6, 18) do
      stub_find("RU000A10AAQ4", [ instrument_short(ticker: "RU000A10AAQ4", type: "bond", class_code: "TQCB", uid: "uid-bond", currency: "rub") ])
      stub_bond_by("uid-bond", { "nominal" => { "units" => "417", "nano" => 710_000_000 }, "amortizationFlag" => true })
      @provider.stubs(:post).with("MarketDataService", "GetCandles", anything).returns("candles" => [ candle("2026-06-10", units: 105, nano: 0) ])
      @provider.stubs(:post).with("MarketDataService", "GetLastPrices", anything).returns("lastPrices" => [ { "price" => { "units" => "103", "nano" => 0 } } ])

      response = @provider.fetch_security_prices(symbol: "RU000A10AAQ4", exchange_operating_mic: "MISX", start_date: Date.new(2026, 6, 10), end_date: Date.new(2026, 6, 18))

      # The historical candle is skipped (today's nominal must not reprice old par);
      # only the live price remains, converted with the current nominal.
      assert_equal [ Date.new(2026, 6, 18) ], response.data.map(&:date)
      assert_equal (BigDecimal("103") / 100 * BigDecimal("417.71")), response.data.first.price
    end
  end

  test "resolve strips an exchange suffix before querying T-Invest" do
    stub_find("T", [ instrument_short(ticker: "T", type: "share", class_code: "TQBR", uid: "uid-t") ])
    stub_instrument_by("uid-t", instrument_full(name: "T-Tech", logo_name: "tcs2.png"))

    response = @provider.fetch_security_info(symbol: "T.MOEX", exchange_operating_mic: "MISX")

    assert response.success?
    assert_equal "https://invest-brands.cdn-tinkoff.ru/tcs2x160.png", response.data.logo_url
  end

  test "fetch_security_prices skips incomplete candles" do
    travel_to Date.new(2026, 6, 18) do
      stub_find("SBER", [ instrument_short(ticker: "SBER", type: "share", class_code: "TQBR", uid: "uid-sber", currency: "rub") ])
      @provider.stubs(:post).with("MarketDataService", "GetCandles", anything).returns(
        "candles" => [ candle("2026-06-17", units: 305, nano: 0, complete: false) ]
      )
      @provider.stubs(:post).with("MarketDataService", "GetLastPrices", anything).returns("lastPrices" => [])

      response = @provider.fetch_security_prices(symbol: "SBER", exchange_operating_mic: "MISX", start_date: Date.new(2026, 6, 17), end_date: Date.new(2026, 6, 17))

      assert_empty response.data
    end
  end

  private

    def stub_find(query, instruments)
      @provider.stubs(:post)
               .with("InstrumentsService", "FindInstrument", has_entry(query: query))
               .returns("instruments" => instruments)
    end

    def stub_instrument_by(uid, instrument)
      @provider.stubs(:post)
               .with("InstrumentsService", "GetInstrumentBy", has_entry(id: uid))
               .returns("instrument" => instrument)
    end

    def stub_bond_by(uid, instrument)
      @provider.stubs(:post)
               .with("InstrumentsService", "BondBy", has_entry(id: uid))
               .returns("instrument" => instrument)
    end

    def instrument_short(ticker:, type:, class_code:, name: nil, uid: "uid", isin: "", currency: "rub", country: "RU", exchange: "moex", tradeable: true)
      {
        "ticker" => ticker, "name" => name || ticker, "instrumentType" => type,
        "classCode" => class_code, "uid" => uid, "isin" => isin, "apiTradeAvailableFlag" => tradeable,
        "currency" => currency, "countryOfRisk" => country, "exchange" => exchange
      }
    end

    def instrument_full(name:, logo_name: nil, exchange: "moex", nominal: nil)
      h = { "name" => name, "exchange" => exchange }
      h["brand"] = { "logoName" => logo_name } unless logo_name.nil?
      h["nominal"] = nominal if nominal
      h
    end

    def candle(date, units:, nano:, complete: true)
      { "time" => "#{date}T00:00:00Z", "close" => { "units" => units.to_s, "nano" => nano }, "isComplete" => complete }
    end
end
