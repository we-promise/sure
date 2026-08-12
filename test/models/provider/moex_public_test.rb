require "test_helper"

class Provider::MoexPublicTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::MoexPublic.new
    @provider.stubs(:throttle_request)
  end

  # ================================
  #            Search
  # ================================

  test "search_securities returns a stock with MOEX MIC and nil country" do
    stub_search("SBER", search_body(
      row(secid: "SBER", shortname: "Sberbank", is_traded: "1", type: "common_share", group: "stock_shares", currencyid: "SUR")
    ))

    response = @provider.search_securities("SBER")

    assert response.success?
    sec = response.data.first
    assert_equal "SBER", sec.symbol
    assert_equal "Sberbank", sec.name
    assert_equal "MISX", sec.exchange_operating_mic
    assert_nil sec.country_code, "MOEX picks must carry a nil country so any family resolves them"
    assert_equal "RUB", sec.currency, "legacy SUR currency code must normalize to RUB"
  end

  test "search_securities returns a fund (LQDT)" do
    stub_search("LQDT", search_body(
      row(secid: "LQDT", shortname: "Liquidity", is_traded: "1", type: "etf_ppif", group: "stock_etf", currencyid: "RUB")
    ))

    response = @provider.search_securities("LQDT")

    assert_equal [ "LQDT" ], response.data.map(&:symbol)
  end

  test "search_securities returns an OFZ bond" do
    stub_search("SU26238RMFS4", search_body(
      row(secid: "SU26238RMFS4", shortname: "OFZ 26238", is_traded: "1", type: "ofz_bond", group: "stock_bonds", currencyid: "SUR")
    ))

    response = @provider.search_securities("SU26238RMFS4")

    assert_equal [ "SU26238RMFS4" ], response.data.map(&:symbol)
  end

  test "search_securities strips the .ME alias suffix before querying ISS" do
    stub_search("SBER", search_body(
      row(secid: "SBER", shortname: "Sberbank", is_traded: "1", type: "common_share", group: "stock_shares")
    ))

    response = @provider.search_securities("SBER.ME")

    assert response.success?
    assert_equal [ "SBER" ], response.data.map(&:symbol)
  end

  test "search_securities strips the .MOEX alias suffix" do
    stub_search("SBER", search_body(
      row(secid: "SBER", shortname: "Sberbank", is_traded: "1", type: "common_share", group: "stock_shares")
    ))

    assert_equal [ "SBER" ], @provider.search_securities("sber.moex").data.map(&:symbol)
  end

  test "search_securities matches an ISIN query natively" do
    isin = "RU0009029540"
    stub_search(isin, search_body(
      row(secid: "SBER", shortname: "Sberbank", isin: isin, is_traded: "1", type: "common_share", group: "stock_shares")
    ))

    assert_equal [ "SBER" ], @provider.search_securities(isin).data.map(&:symbol)
  end

  test "search_securities filters out non-traded instruments" do
    stub_search("SBER", search_body(
      row(secid: "SBERP_OLD", shortname: "delisted", is_traded: "0", type: "preferred_share", group: "stock_shares")
    ))

    assert_empty @provider.search_securities("SBER").data
  end

  test "search_securities excludes indices and futures" do
    stub_search("RTSI", search_body(
      row(secid: "IMOEX", shortname: "MOEX Index", is_traded: "1", type: "common_index", group: "stock_index"),
      row(secid: "RIH6",  shortname: "RTS Future", is_traded: "1", type: "futures",      group: "futures_forts")
    ))

    assert_empty @provider.search_securities("RTSI").data
  end

  test "search_securities dedupes multiple board rows for the same SECID" do
    stub_search("SBER", search_body(
      row(secid: "SBER", shortname: "Sberbank", is_traded: "1", type: "common_share", group: "stock_shares", primary_boardid: "TQBR"),
      row(secid: "SBER", shortname: "Sberbank", is_traded: "1", type: "common_share", group: "stock_shares", primary_boardid: "SMAL")
    ))

    assert_equal [ "SBER" ], @provider.search_securities("SBER").data.map(&:symbol)
  end

  test "search_securities returns empty for a blank query without calling ISS" do
    @provider.expects(:get_json).never
    assert_empty @provider.search_securities("   ").data
  end

  # ================================
  #     Board / engine resolution
  # ================================

  test "resolve_instrument selects the ISS primary board" do
    @provider.stubs(:get_json).with("/securities/SBER.json", anything).returns(instrument_body(
      desc: { "SECID" => "SBER", "SHORTNAME" => "Sberbank", "TYPE" => "common_share", "GROUP" => "stock_shares", "FACEUNIT" => "SUR" },
      boards: [
        board_row(boardid: "SMAL", is_traded: "1", market: "shares", engine: "stock", is_primary: "0", currencyid: "SUR"),
        board_row(boardid: "TQBR", is_traded: "1", market: "shares", engine: "stock", is_primary: "1", currencyid: "SUR")
      ]
    ))

    instrument = @provider.send(:resolve_instrument, "SBER")

    assert_equal "TQBR", instrument[:board]
    assert_equal "shares", instrument[:market]
    assert_equal "stock", instrument[:engine]
    assert_equal "stock", instrument[:kind]
    assert_equal "RUB", instrument[:currency]
  end

  test "resolve_instrument falls back to hardcoded board priority when no primary flag" do
    @provider.stubs(:get_json).with("/securities/SU26238RMFS4.json", anything).returns(instrument_body(
      desc: { "SECID" => "SU26238RMFS4", "SHORTNAME" => "OFZ 26238", "TYPE" => "ofz_bond", "GROUP" => "stock_bonds", "FACEUNIT" => "SUR" },
      boards: [
        board_row(boardid: "EQOB", is_traded: "1", market: "bonds", engine: "stock", is_primary: "0", currencyid: "SUR"),
        board_row(boardid: "TQOB", is_traded: "1", market: "bonds", engine: "stock", is_primary: "0", currencyid: "SUR")
      ]
    ))

    instrument = @provider.send(:resolve_instrument, "SU26238RMFS4")

    assert_equal "TQOB", instrument[:board], "TQOB precedes EQOB in BOARD_PRIORITY"
    assert_equal "bond", instrument[:kind]
  end

  # ================================
  #          Security info
  # ================================

  test "fetch_security_info maps kind and omits an exchange website" do
    @provider.stubs(:resolve_instrument).returns(bond_instrument)

    response = @provider.fetch_security_info(symbol: "SU26238RMFS4", exchange_operating_mic: "MISX")

    assert response.success?
    assert_equal "bond", response.data.kind
    assert_equal "MISX", response.data.exchange_operating_mic
    # No issuer website: moex.com is the exchange, not the issuer, and would make
    # Brandfetch render the exchange logo for every instrument.
    assert_nil response.data.links
  end

  # ================================
  #        Security prices
  # ================================

  test "fetch_security_prices uses LAST from the marketdata fallback chain" do
    @provider.stubs(:resolve_instrument).returns(stock_instrument)
    stub_history([])
    stub_current_price(
      securities: { "facevalue" => nil, "faceunit" => "SUR", "currencyid" => "SUR", "prevprice" => "300.0" },
      marketdata: { "last" => "320.5", "marketprice" => "319.0", "lcloseprice" => "318.0", "waprice" => "319.2" }
    )

    response = @provider.fetch_security_price(symbol: "SBER", exchange_operating_mic: "MISX", date: Date.current)

    assert response.success?
    assert_in_delta 320.5, response.data.price
    assert_equal "RUB", response.data.currency
    assert_equal "MISX", response.data.exchange_operating_mic
  end

  test "fetch_security_prices falls back to PREVPRICE when marketdata is empty" do
    @provider.stubs(:resolve_instrument).returns(stock_instrument)
    stub_history([])
    stub_current_price(
      securities: { "facevalue" => nil, "currencyid" => "SUR", "prevprice" => "305.0" },
      marketdata: { "last" => nil, "marketprice" => nil, "lcurrentprice" => nil, "lcloseprice" => nil, "waprice" => nil }
    )

    response = @provider.fetch_security_price(symbol: "SBER", exchange_operating_mic: "MISX", date: Date.current)

    assert response.success?
    assert_in_delta 305.0, response.data.price
  end

  test "fetch_security_prices reads past dates from the history endpoint" do
    date = Date.current - 5
    @provider.stubs(:resolve_instrument).returns(stock_instrument)
    stub_history([ history_row(tradedate: date.to_s, close: "311.4") ])

    response = @provider.fetch_security_price(symbol: "SBER", exchange_operating_mic: "MISX", date: date)

    assert response.success?
    assert_equal date, response.data.date
    assert_in_delta 311.4, response.data.price
    assert_equal "RUB", response.data.currency
  end

  test "fetch_security_prices paginates history via start=" do
    start_date = Date.current - 200
    end_date = Date.current - 10
    page0 = Array.new(100) { |i| history_row(tradedate: (start_date + i).to_s, close: "100.0") }
    page1 = Array.new(50)  { |i| history_row(tradedate: (start_date + 100 + i).to_s, close: "101.0") }

    @provider.stubs(:resolve_instrument).returns(stock_instrument)
    @provider.stubs(:get_json).with(regexp_matches(%r{^/history/}), has_entry("start" => 0)).returns(history_block(page0))
    @provider.stubs(:get_json).with(regexp_matches(%r{^/history/}), has_entry("start" => 100)).returns(history_block(page1))

    response = @provider.fetch_security_prices(
      symbol: "SBER", exchange_operating_mic: "MISX", start_date: start_date, end_date: end_date
    )

    assert response.success?
    assert_equal 150, response.data.size
  end

  test "fetch_security_prices skips a row with an unparseable date instead of failing" do
    good_date = Date.current - 5
    @provider.stubs(:resolve_instrument).returns(stock_instrument)
    stub_history([
      history_row(tradedate: "not-a-date", close: "300.0"),
      history_row(tradedate: good_date.to_s, close: "311.4")
    ])

    response = @provider.fetch_security_prices(
      symbol: "SBER", exchange_operating_mic: "MISX", start_date: Date.current - 7, end_date: good_date
    )

    assert response.success?
    assert_equal [ good_date ], response.data.map(&:date)
  end

  test "fetch_security_prices converts bond percent-of-par to currency via FACEVALUE" do
    date = Date.current - 5
    @provider.stubs(:resolve_instrument).returns(bond_instrument)
    stub_history([ history_row(tradedate: date.to_s, close: "98.5", facevalue: "1000.0", faceunit: "SUR") ])

    response = @provider.fetch_security_price(symbol: "SU26238RMFS4", exchange_operating_mic: "MISX", date: date)

    assert response.success?
    assert_in_delta 985.0, response.data.price, 0.001, "98.5% of a 1000 par must be 985"
    assert_equal "RUB", response.data.currency
  end

  test "fetch_security_prices stamps eurobond currency from ISS FACEUNIT" do
    date = Date.current - 5
    @provider.stubs(:resolve_instrument).returns(eurobond_instrument)
    stub_history([ history_row(tradedate: date.to_s, close: "102.0", facevalue: "1000.0", faceunit: "USD") ])

    response = @provider.fetch_security_price(symbol: "RU000A0JX0J2", exchange_operating_mic: "MISX", date: date)

    assert_equal "USD", response.data.currency
    assert_in_delta 1020.0, response.data.price, 0.001
  end

  test "fetch_security_prices reads per-row FACEVALUE for amortizing bonds" do
    d1 = Date.current - 6
    d2 = Date.current - 5
    @provider.stubs(:resolve_instrument).returns(bond_instrument)
    stub_history([
      history_row(tradedate: d1.to_s, close: "100.0", facevalue: "1000.0", faceunit: "SUR"),
      history_row(tradedate: d2.to_s, close: "100.0", facevalue: "700.0",  faceunit: "SUR")
    ])

    response = @provider.fetch_security_prices(
      symbol: "RU000AMORT", exchange_operating_mic: "MISX", start_date: d1, end_date: d2
    )

    prices = response.data.sort_by(&:date)
    assert_in_delta 1000.0, prices.first.price, 0.001
    assert_in_delta 700.0,  prices.last.price, 0.001, "amortized face value must drive the second day's clean price"
  end

  test "fetch_security_price raises InvalidSecurityPriceError when nothing is found" do
    date = Date.current - 5
    @provider.stubs(:resolve_instrument).returns(stock_instrument)
    stub_history([])

    response = @provider.fetch_security_price(symbol: "SBER", exchange_operating_mic: "MISX", date: date)

    assert_not response.success?
    assert_instance_of Provider::MoexPublic::InvalidSecurityPriceError, response.error
  end

  # ================================
  #          Exchange rates
  # ================================

  test "fetch_exchange_rate USD to RUB is the direct selt quote" do
    date = Date.current - 5
    stub_fx_history("USD000UTSTOM", [ fx_row(tradedate: date.to_s, close: "90.5") ])

    response = @provider.fetch_exchange_rate(from: "USD", to: "RUB", date: date)

    assert response.success?
    assert_in_delta 90.5, response.data.rate.to_f
    assert_equal "USD", response.data.from
    assert_equal "RUB", response.data.to
  end

  test "fetch_exchange_rate looks back to the prior trading day on a non-trading date" do
    non_trading_day = Date.current - 5
    prior_trading_day = non_trading_day - 2
    # ISS returns nothing for the weekend/holiday itself, only the earlier close.
    stub_fx_history("USD000UTSTOM", [ fx_row(tradedate: prior_trading_day.to_s, close: "91.0") ])

    response = @provider.fetch_exchange_rate(from: "USD", to: "RUB", date: non_trading_day)

    assert response.success?
    assert_equal prior_trading_day, response.data.date
    assert_in_delta 91.0, response.data.rate.to_f
  end

  test "fetch_exchange_rate RUB to USD inverts the selt quote" do
    date = Date.current - 5
    stub_fx_history("USD000UTSTOM", [ fx_row(tradedate: date.to_s, close: "90.5") ])

    response = @provider.fetch_exchange_rate(from: "RUB", to: "USD", date: date)

    assert response.success?
    assert_in_delta (1.0 / 90.5), response.data.rate.to_f, 0.0000001
  end

  test "fetch_exchange_rate supports EUR and CNY" do
    date = Date.current - 5
    stub_fx_history("EUR_RUB__TOM", [ fx_row(tradedate: date.to_s, close: "98.1") ])
    stub_fx_history("CNYRUB_TOM",   [ fx_row(tradedate: date.to_s, close: "12.4") ])

    eur = @provider.fetch_exchange_rate(from: "EUR", to: "RUB", date: date)
    cny = @provider.fetch_exchange_rate(from: "CNY", to: "RUB", date: date)

    assert_in_delta 98.1, eur.data.rate.to_f
    assert_in_delta 12.4, cny.data.rate.to_f
  end

  test "fetch_exchange_rates returns empty for a non-RUB-crossed pair" do
    @provider.expects(:get_json).never

    response = @provider.fetch_exchange_rates(
      from: "USD", to: "EUR", start_date: Date.current - 5, end_date: Date.current - 1
    )

    assert response.success?
    assert_empty response.data
  end

  test "fetch_exchange_rate fails (no crash) for a non-RUB-crossed pair" do
    @provider.expects(:get_json).never

    response = @provider.fetch_exchange_rate(from: "USD", to: "EUR", date: Date.current - 1)

    assert_not response.success?
  end

  test "fetch_exchange_rates returns a sorted range of rates" do
    start_date = Date.current - 5
    end_date = Date.current - 1
    rows = (0..4).map { |i| fx_row(tradedate: (start_date + i).to_s, close: (90 + i).to_s) }
    stub_fx_history("USD000UTSTOM", rows)

    response = @provider.fetch_exchange_rates(
      from: "USD", to: "RUB", start_date: start_date, end_date: end_date
    )

    assert response.success?
    assert_equal 5, response.data.size
    assert_equal start_date, response.data.first.date
    assert_equal end_date, response.data.last.date
  end

  # ================================
  #      Error / response wrapping
  # ================================

  test "search_securities wraps provider errors via with_provider_response" do
    @provider.stubs(:get_json).raises(StandardError.new("ISS unreachable"))

    response = @provider.search_securities("SBER")

    assert_not response.success?
    assert_instance_of Provider::MoexPublic::Error, response.error
  end

  test "max_history_days is nil (full history)" do
    assert_nil @provider.max_history_days
  end

  # ================================
  #            Helpers
  # ================================

  private

    # ----- instrument stubs -----

    def stock_instrument
      { secid: "SBER", engine: "stock", market: "shares", board: "TQBR", currency: "RUB", name: "Sberbank", kind: "stock" }
    end

    def bond_instrument
      { secid: "SU26238RMFS4", engine: "stock", market: "bonds", board: "TQOB", currency: "RUB", name: "OFZ 26238", kind: "bond" }
    end

    def eurobond_instrument
      { secid: "RU000A0JX0J2", engine: "stock", market: "bonds", board: "TQOD", currency: "USD", name: "Eurobond", kind: "bond" }
    end

    # ----- column-array block builders -----

    def block(columns, rows)
      { "columns" => columns, "data" => rows.map { |r| columns.map { |c| r[c] } } }
    end

    SEARCH_COLUMNS = %w[secid shortname isin is_traded type group primary_boardid currencyid faceunit].freeze

    def row(**attrs)
      attrs.transform_keys(&:to_s)
    end

    def search_body(*rows)
      { "securities" => block(SEARCH_COLUMNS, rows) }
    end

    def stub_search(query, body)
      @provider.stubs(:get_json).with("/securities.json", has_entry("q" => query)).returns(body)
    end

    DESCRIPTION_COLUMNS = %w[name title value].freeze
    BOARD_COLUMNS = %w[secid boardid title is_traded market engine is_primary currencyid].freeze

    def board_row(**attrs)
      { "secid" => "SBER", "title" => attrs[:boardid] }.merge(attrs.transform_keys(&:to_s))
    end

    def instrument_body(desc:, boards:)
      {
        "description" => block(DESCRIPTION_COLUMNS, desc.map { |name, value| { "name" => name, "title" => name, "value" => value } }),
        "boards" => block(BOARD_COLUMNS, boards)
      }
    end

    PRICE_SECURITIES_COLUMNS = %w[secid facevalue faceunit currencyid prevprice].freeze
    PRICE_MARKETDATA_COLUMNS = %w[secid last marketprice lcurrentprice lcloseprice waprice].freeze

    def stub_current_price(securities:, marketdata:)
      body = {
        "securities" => block(PRICE_SECURITIES_COLUMNS, [ securities ]),
        "marketdata" => block(PRICE_MARKETDATA_COLUMNS, [ marketdata ])
      }
      @provider.stubs(:get_json).with(regexp_matches(%r{^/engines/}), anything).returns(body)
    end

    HISTORY_COLUMNS = %w[tradedate secid close legalcloseprice facevalue faceunit currencyid].freeze

    def history_row(**attrs)
      attrs.transform_keys(&:to_s)
    end

    def history_block(rows)
      { "history" => block(HISTORY_COLUMNS, rows) }
    end

    def stub_history(rows)
      @provider.stubs(:get_json).with(regexp_matches(%r{^/history/engines/(?!currency)}), anything).returns(history_block(rows))
    end

    FX_HISTORY_COLUMNS = %w[tradedate secid close waprice].freeze

    def fx_row(**attrs)
      attrs.transform_keys(&:to_s)
    end

    def stub_fx_history(instrument, rows)
      body = { "history" => block(FX_HISTORY_COLUMNS, rows) }
      @provider.stubs(:get_json).with(regexp_matches(%r{/history/engines/currency/.*#{Regexp.escape(instrument)}}), anything).returns(body)
    end
end
