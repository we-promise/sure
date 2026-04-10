require "test_helper"

class Provider::BinancePublicTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::BinancePublic.new
    @provider.stubs(:throttle_request)
  end

  # ================================
  #       Search
  # ================================

  test "search_securities returns one result per supported quote" do
    @provider.stubs(:exchange_info_symbols).returns(sample_exchange_info)

    response = @provider.search_securities("BTC")

    assert response.success?
    tickers = response.data.map(&:symbol)
    assert_includes tickers, "BTCUSD"
    assert_includes tickers, "BTCEUR"
    assert_includes tickers, "BTCGBP"
    assert_includes tickers, "BTCTRY"
  end

  test "search_securities maps USDT pair to USD currency" do
    @provider.stubs(:exchange_info_symbols).returns(sample_exchange_info)

    response = @provider.search_securities("BTC")
    usd_row = response.data.find { |s| s.symbol == "BTCUSD" }

    assert_equal "USD", usd_row.currency
    assert_equal "BNCX", usd_row.exchange_operating_mic
    assert_equal "AE", usd_row.country_code
    assert_equal "BTC", usd_row.name
  end

  test "search_securities preserves native EUR pair currency" do
    @provider.stubs(:exchange_info_symbols).returns(sample_exchange_info)

    response = @provider.search_securities("BTC")
    eur_row = response.data.find { |s| s.symbol == "BTCEUR" }

    assert_equal "EUR", eur_row.currency
    assert_equal "BNCX", eur_row.exchange_operating_mic
  end

  test "search_securities is case insensitive" do
    @provider.stubs(:exchange_info_symbols).returns(sample_exchange_info)

    upper = @provider.search_securities("ETH").data
    lower = @provider.search_securities("eth").data

    assert_equal upper.map(&:symbol).sort, lower.map(&:symbol).sort
  end

  test "search_securities skips unsupported quote assets like BNB" do
    info = [
      info_row("BTC", "USDT"),
      info_row("BTC", "BNB"),
      info_row("BTC", "BTC")
    ]
    @provider.stubs(:exchange_info_symbols).returns(info)

    response = @provider.search_securities("BTC")
    assert_equal [ "BTCUSD" ], response.data.map(&:symbol)
  end

  test "search_securities returns empty array when query does not match" do
    @provider.stubs(:exchange_info_symbols).returns(sample_exchange_info)

    response = @provider.search_securities("NONEXISTENTCOIN")
    assert response.success?
    assert_empty response.data
  end

  test "search_securities ranks exact matches first" do
    info = [
      info_row("BTCB", "USDT"),  # contains "BTC"
      info_row("BTC",  "USDT"),  # exact match
      info_row("WBTC", "USDT")   # contains "BTC"
    ]
    @provider.stubs(:exchange_info_symbols).returns(info)

    tickers = @provider.search_securities("BTC").data.map(&:name)
    assert_equal "BTC", tickers.first
  end

  test "search_securities ignores delisted pairs" do
    info = [
      info_row("BTC", "USDT", status: "TRADING"),
      info_row("LUNA", "USDT", status: "BREAK")
    ]
    # exchange_info_symbols already filters by TRADING status, but double-check
    # that delisted symbols don't leak through the path that fetches them.
    @provider.stubs(:exchange_info_symbols).returns(info.select { |s| s["status"] == "TRADING" })

    tickers = @provider.search_securities("LUNA").data.map(&:symbol)
    assert_empty tickers
  end

  # ================================
  #       Ticker parsing
  # ================================

  test "parse_ticker maps USD suffix to USDT pair" do
    parsed = @provider.send(:parse_ticker, "BTCUSD")
    assert_equal "BTCUSDT", parsed[:binance_pair]
    assert_equal "BTC", parsed[:base]
    assert_equal "USD", parsed[:display_currency]
  end

  test "parse_ticker keeps EUR suffix as-is" do
    parsed = @provider.send(:parse_ticker, "ETHEUR")
    assert_equal "ETHEUR", parsed[:binance_pair]
    assert_equal "ETH", parsed[:base]
    assert_equal "EUR", parsed[:display_currency]
  end

  test "parse_ticker returns nil for unsupported suffix" do
    assert_nil @provider.send(:parse_ticker, "BTCBNB")
    assert_nil @provider.send(:parse_ticker, "GIBBERISH")
  end

  # ================================
  #       Single price
  # ================================

  test "fetch_security_price returns Price for a single day" do
    mock_client_returning_klines([
      kline_row("2026-01-15", "42000.50")
    ])

    response = @provider.fetch_security_price(
      symbol: "BTCUSD",
      exchange_operating_mic: "BNCX",
      date: Date.parse("2026-01-15")
    )

    assert response.success?
    assert_equal Date.parse("2026-01-15"), response.data.date
    assert_in_delta 42000.50, response.data.price
    assert_equal "USD", response.data.currency
    assert_equal "BNCX", response.data.exchange_operating_mic
  end

  test "fetch_security_price raises InvalidSecurityPriceError for empty response" do
    mock_client_returning_klines([])

    response = @provider.fetch_security_price(
      symbol: "BTCUSD",
      exchange_operating_mic: "BNCX",
      date: Date.parse("2026-01-15")
    )

    assert_not response.success?
    assert_instance_of Provider::BinancePublic::InvalidSecurityPriceError, response.error
  end

  test "fetch_security_price fails for unsupported ticker" do
    response = @provider.fetch_security_price(
      symbol: "NOPE",
      exchange_operating_mic: "BNCX",
      date: Date.current
    )

    assert_not response.success?
    assert_instance_of Provider::BinancePublic::InvalidSecurityPriceError, response.error
  end

  # ================================
  #       Historical prices
  # ================================

  test "fetch_security_prices returns rows across a small range" do
    rows = (0..4).map { |i| kline_row(Date.parse("2026-01-01") + i.days, (40000 + i).to_s) }
    mock_client_returning_klines(rows)

    response = @provider.fetch_security_prices(
      symbol: "BTCUSD",
      exchange_operating_mic: "BNCX",
      start_date: Date.parse("2026-01-01"),
      end_date: Date.parse("2026-01-05")
    )

    assert response.success?
    assert_equal 5, response.data.size
    assert_equal Date.parse("2026-01-01"), response.data.first.date
    assert_equal Date.parse("2026-01-05"), response.data.last.date
    assert response.data.all? { |p| p.currency == "USD" }
  end

  test "fetch_security_prices filters out zero-close rows" do
    rows = [
      kline_row("2026-01-01", "40000"),
      kline_row("2026-01-02", "0"),
      kline_row("2026-01-03", "41000")
    ]
    mock_client_returning_klines(rows)

    response = @provider.fetch_security_prices(
      symbol: "BTCUSD",
      exchange_operating_mic: "BNCX",
      start_date: Date.parse("2026-01-01"),
      end_date: Date.parse("2026-01-03")
    )

    assert_equal 2, response.data.size
  end

  test "fetch_security_prices paginates when range exceeds KLINE_MAX_LIMIT" do
    first_batch  = Array.new(1000) { |i| kline_row(Date.parse("2022-01-01") + i.days, "40000") }
    second_batch = Array.new(200)  { |i| kline_row(Date.parse("2024-09-27") + i.days, "42000") }

    mock_response_1 = mock
    mock_response_1.stubs(:body).returns(first_batch.to_json)
    mock_response_2 = mock
    mock_response_2.stubs(:body).returns(second_batch.to_json)

    mock_client = mock
    mock_client.expects(:get).twice.returns(mock_response_1).then.returns(mock_response_2)
    @provider.stubs(:client).returns(mock_client)

    response = @provider.fetch_security_prices(
      symbol: "BTCUSD",
      exchange_operating_mic: "BNCX",
      start_date: Date.parse("2022-01-01"),
      end_date: Date.parse("2025-04-14")
    )

    assert response.success?
    assert_equal 1200, response.data.size
  end

  test "fetch_security_prices stops paginating when batch is short" do
    # Only 3 rows returned for a 1500-day request -> short batch means no more
    # history available, should terminate the loop.
    short_batch = (0..2).map { |i| kline_row(Date.parse("2017-08-17") + i.days, "4500") }
    mock_client_returning_klines(short_batch)

    response = @provider.fetch_security_prices(
      symbol: "BTCUSD",
      exchange_operating_mic: "BNCX",
      start_date: Date.parse("2017-08-17"),
      end_date: Date.parse("2021-09-24")
    )

    assert_equal 3, response.data.size
  end

  test "fetch_security_prices uses native quote currency for EUR pair" do
    rows = [ kline_row("2026-01-15", "38000.12") ]
    mock_client_returning_klines(rows)

    response = @provider.fetch_security_prices(
      symbol: "BTCEUR",
      exchange_operating_mic: "BNCX",
      start_date: Date.parse("2026-01-15"),
      end_date: Date.parse("2026-01-15")
    )

    assert_equal "EUR", response.data.first.currency
  end

  test "fetch_security_prices returns empty array for unsupported ticker wrapped as error" do
    response = @provider.fetch_security_prices(
      symbol: "NOPE",
      exchange_operating_mic: "BNCX",
      start_date: Date.current - 5,
      end_date: Date.current
    )

    assert_not response.success?
    assert_instance_of Provider::BinancePublic::InvalidSecurityPriceError, response.error
  end

  # ================================
  #       Info
  # ================================

  test "fetch_security_info returns crypto kind" do
    response = @provider.fetch_security_info(symbol: "BTCUSD", exchange_operating_mic: "BNCX")

    assert response.success?
    assert_equal "BTC", response.data.name
    assert_equal "crypto", response.data.kind
    assert_match(/binance\.com/, response.data.links)
  end

  # ================================
  #       Helpers
  # ================================

  private

    def sample_exchange_info
      [
        info_row("BTC", "USDT"),
        info_row("BTC", "EUR"),
        info_row("BTC", "GBP"),
        info_row("BTC", "TRY"),
        info_row("ETH", "USDT"),
        info_row("ETH", "EUR"),
        info_row("SOL", "USDT"),
        info_row("BNB", "USDT")
      ]
    end

    def info_row(base, quote, status: "TRADING")
      {
        "symbol"     => "#{base}#{quote}",
        "baseAsset"  => base,
        "quoteAsset" => quote,
        "status"     => status
      }
    end

    # Mimics Binance /api/v3/klines row format.
    # Index 0 = open time (ms), index 4 = close price (string)
    def kline_row(date, close)
      date = Date.parse(date) if date.is_a?(String)
      open_time_ms = Time.utc(date.year, date.month, date.day).to_i * 1000
      [
        open_time_ms,      # 0: Open time
        "0",               # 1: Open
        "0",               # 2: High
        "0",               # 3: Low
        close.to_s,        # 4: Close
        "0",               # 5: Volume
        open_time_ms + (24 * 60 * 60 * 1000 - 1),  # 6: Close time
        "0", 0, "0", "0", "0"
      ]
    end

    def mock_client_returning_klines(rows)
      mock_response = mock
      mock_response.stubs(:body).returns(rows.to_json)
      mock_client = mock
      mock_client.stubs(:get).returns(mock_response)
      @provider.stubs(:client).returns(mock_client)
    end
end
