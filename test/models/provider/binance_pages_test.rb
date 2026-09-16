require "test_helper"

class Provider::BinancePagesTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body, keyword_init: true)

  setup do
    @client = Provider::Binance.new(api_key: "test-key", api_secret: "test-secret")
    @client.stubs(:timestamp_params).returns({ "timestamp" => "1234567890000", "recvWindow" => "5000" })
  end

  test "bounded portfolio readers retain exact decimals and sign the complete canonical query" do
    Provider::Binance.expects(:get).once.with { |path, options|
      pairs = URI.decode_www_form(options[:query]).to_h
      signature = pairs.delete("signature")
      path == "/api/v3/account" && options[:base_uri] == Provider::Binance::SPOT_BASE_URL &&
        options[:headers]["X-MBX-APIKEY"] == "test-key" && pairs["timestamp"] == "1234567890000" &&
        signature == OpenSSL::HMAC.hexdigest("sha256", "test-secret", URI.encode_www_form(pairs.sort))
    }.returns(response('{"balances":[{"asset":"BTC","free":0.123456789012345678,"locked":"0"}]}'))

    result = @client.get_portfolio_page("spot")

    assert_equal BigDecimal("0.123456789012345678"), result[:items].first["free"]
    assert_equal result[:items], result[:evidence]["balances"]
    assert_nil result[:next_cursor]
  end

  test "Earn requests exactly one numbered page with explicit maximum size" do
    rows = Array.new(100) { { asset: "USDT", totalAmount: "1" } }
    Provider::Binance.expects(:get).once.with { |path, options|
      params = URI.decode_www_form(options[:query]).to_h
      path == "/sapi/v1/simple-earn/flexible/position" && params["current"] == "1" && params["size"] == "100"
    }.returns(response({ rows: rows, total: 101 }.to_json))

    result = @client.get_portfolio_page("earn_flexible")

    assert_equal 100, result[:items].size
    assert_equal "2", result[:next_cursor]
  end

  test "malformed or inconsistent source collections never become empty complete results" do
    [ {}, { rows: nil, total: 0 }, { rows: [ nil ], total: 1 }, { rows: [], total: 101 },
      { rows: [ { asset: "USDT" } ], total: "1" }, { rows: [ { asset: "USDT" } ], total: 101 } ].each do |payload|
      Provider::Binance.expects(:get).returns(response(payload.to_json))
      assert_raises(Provider::Binance::ApiError) { @client.get_portfolio_page("earn_locked") }
    end
  end

  test "trade readers keep futures and spot hosts separate and never combine IDs with timestamps" do
    Provider::Binance.expects(:get).once.with { |path, options|
      params = URI.decode_www_form(options[:query]).to_h
      path == "/fapi/v1/userTrades" && options[:base_uri] == Provider::Binance::FUTURES_BASE_URL &&
        params["fromId"] == "1001" && params["limit"] == "1000" && !params.key?("startTime") && !params.key?("endTime")
    }.returns(response("[]"))
    assert_empty @client.get_trades_page("BTCUSDT", market: "futures", from_id: 1001)[:items]

    assert_raises(Provider::Binance::ApiError) { @client.get_trades_page("BTCUSDT", market: "spot", from_id: 1, start_time: 1, end_time: 2) }
    assert_raises(Provider::Binance::ApiError) { @client.get_trades_page("BTCUSDT", market: "spot", start_time: 0, end_time: 86_400_000) }
    assert_raises(Provider::Binance::ApiError) { @client.get_trades_page("BTCUSDT", market: "futures", start_time: 0, end_time: 604_800_000) }
    assert_raises(Provider::Binance::ApiError) { @client.get_trades_page("BTC/USDT", market: "spot") }
  end

  test "P2P returns one complete response and its next page without fetching the other side" do
    rows = Array.new(100) { { orderNumber: "order" } }
    Provider::Binance.expects(:get).once.with { |path, options|
      params = URI.decode_www_form(options[:query]).to_h
      path == "/sapi/v1/c2c/orderMatch/listUserOrderHistory" && params["tradeType"] == "SELL" &&
        params["page"] == "3" && params["rows"] == "100"
    }.returns(response({ data: rows, success: true }.to_json))

    result = @client.get_p2p_page(trade_type: "SELL", start_time: 100, end_time: 200, page: 3)

    assert_equal "4", result[:next_cursor]
    assert_equal rows.map(&:stringify_keys), result[:items]
  end

  test "unsuccessful P2P envelopes cannot advance history" do
    Provider::Binance.expects(:get).returns(response({ success: false, data: [] }.to_json))
    assert_raises(Provider::Binance::ApiError) { @client.get_p2p_page(trade_type: "BUY", start_time: 0, end_time: 1) }
  end

  test "historical prices use a UTC daily candle and public readers send no credential headers" do
    Provider::Binance.expects(:get).once.with("/api/v3/klines", query: {
      symbol: "BTCUSDT", interval: "1d", startTime: Time.utc(2026, 2, 14).to_i * 1000, limit: 1
    }).returns(response('[[1771027200000,"1","2","0",12345.123456789012345678]]'))

    result = @client.get_price_page("BTCUSDT", date: Date.new(2026, 2, 14))

    assert_equal BigDecimal("12345.123456789012345678"), result[:items].first["price"]
    assert_equal BigDecimal("12345.123456789012345678"), result[:evidence].first[4]
  end

  test "typed API errors and malformed bodies omit private remote messages" do
    { 401 => Provider::Binance::AuthenticationError, 403 => Provider::Binance::AuthenticationError,
      418 => Provider::Binance::RateLimitError, 429 => Provider::Binance::RateLimitError, 500 => Provider::Binance::ApiError }.each do |status, type|
      body = status == 418 ? "private account details" : '{"msg":"private account details"}'
      Provider::Binance.expects(:get).returns(response(body, code: status))
      error = assert_raises(type) { @client.get_portfolio_page("spot") }
      refute_includes error.message, "private account details"
    end
    Provider::Binance.expects(:get).returns(response('{"code":-1121,"msg":"private symbol details"}', code: 400))
    assert_raises(Provider::Binance::InvalidSymbolError) { @client.get_trades_page("ETHBTC", market: "spot") }
    Provider::Binance.expects(:get).returns(response("malformed private response"))
    error = assert_raises(Provider::Binance::ApiError) { @client.get_portfolio_page("spot") }
    assert_nil error.cause
  end

  private
    def response(body, code: 200)
      Response.new(code: code, body: body)
    end
end
