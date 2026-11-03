require "test_helper"

class Provider::EtoroTest < ActiveSupport::TestCase
  BASE = "https://public-api.etoro.com/api/v1".freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  setup do
    @provider = Provider::Etoro.new(api_key: " public-key ", user_key: "user-key")
    @provider.stubs(:sleep)
  end

  test "sends both keys and a fresh request id" do
    request = stub_request(:get, "#{BASE}/trading/info/real/pnl")
      .with { |req| req.headers["X-Api-Key"] == "public-key" && req.headers["X-User-Key"] == "user-key" && req.headers["X-Request-Id"].match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) }
      .to_return(status: 200, body: { clientPortfolio: { positions: [] } }.to_json, headers: JSON_HEADERS)

    assert_equal({ "clientPortfolio" => { "positions" => [] } }, @provider.fetch_portfolio)
    assert_requested request
  end

  test "asks for zero-balance accounts" do
    request = stub_request(:get, "#{BASE}/balances")
      .with(query: { accountTypes: "Trading", includeZeroBalances: "true", expand: "equityDetails" })
      .to_return(status: 200, body: { balances: [ { accountId: "acc-1", accountType: "Trading", balance: 0 } ] }.to_json, headers: JSON_HEADERS)

    assert_equal 0, @provider.fetch_balances.dig("balances", 0, "balance")
    assert_requested request
  end

  test "requests a trade history page by number, 500 trades a page" do
    request = stub_request(:get, "#{BASE}/trading/info/trade/history")
      .with(query: { minDate: "2025-10-25", page: "2", pageSize: "500" })
      .to_return(status: 200, body: [ { positionId: 7 } ].to_json, headers: JSON_HEADERS)

    assert_equal [ { "positionId" => 7 } ], @provider.fetch_trade_history_page(min_date: Date.new(2025, 10, 25), page: 2)
    assert_requested request
  end

  test "reads a trade history page wrapped in an object" do
    stub_request(:get, "#{BASE}/trading/info/trade/history")
      .with(query: hash_including({}))
      .to_return(status: 200, body: { trades: [ { positionId: 7 } ] }.to_json, headers: JSON_HEADERS)

    assert_equal [ { "positionId" => 7 } ], @provider.fetch_trade_history_page(min_date: Date.new(2025, 10, 25), page: 1)
  end

  test "an unrecognised trade history body is an error, not an empty page" do
    stub_request(:get, "#{BASE}/trading/info/trade/history")
      .with(query: hash_including({}))
      .to_return(status: 200, body: { message: "maintenance" }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Etoro::ApiError) do
      @provider.fetch_trade_history_page(min_date: Date.new(2025, 10, 25), page: 1)
    end
  end

  test "balance history uses the lowercase account type in the path" do
    request = stub_request(:get, "#{BASE}/balances/trading/acc-1/history")
      .with(query: { fromDate: "2025-10-25", toDate: "2026-10-24" })
      .to_return(status: 200, body: { snapshots: [] }.to_json, headers: JSON_HEADERS)

    @provider.fetch_balance_history(account_type: "Trading", account_id: "acc-1", from_date: Date.new(2025, 10, 25), to_date: Date.new(2026, 10, 24))

    assert_requested request
  end

  test "waits out a rate limit and retries" do
    stub_request(:get, "#{BASE}/balances")
      .with(query: { accountTypes: "Trading", includeZeroBalances: "true", expand: "equityDetails" })
      .to_return(
        { status: 429, headers: { "Retry-After" => "5" } },
        { status: 200, body: { balances: [] }.to_json, headers: JSON_HEADERS }
      )

    @provider.expects(:sleep).with(5).once

    assert_equal({ "balances" => [] }, @provider.fetch_balances)
  end

  test "a rate limit that outlasts the retries is an API error with status 429" do
    stub_request(:get, "#{BASE}/balances").with(query: hash_including({})).to_return(status: 429)

    error = assert_raises(Provider::Etoro::RateLimitError) { @provider.fetch_balances }

    assert_kind_of Provider::Etoro::ApiError, error
    assert_equal 429, error.status_code
  end

  test "retries a bad gateway with backoff" do
    stub_request(:get, "#{BASE}/balances/trading/acc-1/history")
      .with(query: hash_including({}))
      .to_return({ status: 502 }, { status: 200, body: { snapshots: [] }.to_json, headers: JSON_HEADERS })

    @provider.expects(:sleep).with(2).once

    assert_equal({ "snapshots" => [] }, fetch_history)
  end

  test "an outage that outlasts the retries is a transient error with its status" do
    stub_request(:get, "#{BASE}/balances/trading/acc-1/history").with(query: hash_including({})).to_return(status: 503)

    @provider.expects(:sleep).with(2).once
    @provider.expects(:sleep).with(4).once

    error = assert_raises(Provider::Etoro::TransientError) { fetch_history }
    assert_equal 503, error.status_code
  end

  test "other failures are API errors with their status" do
    stub_request(:get, "#{BASE}/balances/trading/acc-1/history").with(query: hash_including({})).to_return(status: 404)

    error = assert_raises(Provider::Etoro::ApiError) { fetch_history }

    assert_not_kind_of Provider::Etoro::TransientError, error
    assert_equal 404, error.status_code
  end

  test "a connection that keeps failing is a transient error" do
    stub_request(:get, "#{BASE}/trading/info/real/pnl").to_raise(Errno::ECONNRESET)

    error = assert_raises(Provider::Etoro::TransientError) { @provider.fetch_portfolio }

    assert_kind_of Errno::ECONNRESET, error.cause
  end

  [ Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EPIPE, Net::HTTPBadResponse, Zlib::BufError ].each do |error_class|
    test "a request that keeps failing with #{error_class} is retried, then a transient error" do
      request = stub_request(:get, "#{BASE}/trading/info/real/pnl").to_raise(error_class)

      error = assert_raises(Provider::Etoro::TransientError) { @provider.fetch_portfolio }

      assert_kind_of error_class, error.cause
      assert_requested request, times: 3
    end
  end

  test "a programming error is not retried" do
    request = stub_request(:get, "#{BASE}/trading/info/real/pnl").to_raise(ArgumentError)

    assert_raises(ArgumentError) { @provider.fetch_portfolio }
    assert_requested request, times: 1
  end

  test "an unrecognised instruments body is an error, not an empty list" do
    stub_request(:get, "#{BASE}/market-data/instruments")
      .with(query: hash_including({}))
      .to_return(status: 200, body: { message: "maintenance" }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Etoro::ApiError) { @provider.fetch_instruments([ 1001 ]) }
  end

  test "a body that is not JSON is a transient error" do
    stub_request(:get, "#{BASE}/trading/info/real/pnl")
      .to_return({ status: 200, body: "<html>Bad gateway</html>", headers: { "Content-Type" => "text/html" } })

    assert_raises(Provider::Etoro::TransientError) { @provider.fetch_portfolio }
  end

  test "a JSON body cut short is a transient error" do
    stub_request(:get, "#{BASE}/trading/info/real/pnl")
      .to_return({ status: 200, body: "{\"clientPortfolio\": {", headers: JSON_HEADERS })

    assert_raises(Provider::Etoro::TransientError) { @provider.fetch_portfolio }
  end

  test "rejected credentials raise an authentication error" do
    stub_request(:get, "#{BASE}/balances")
      .with(query: hash_including({}))
      .to_return({ status: 401, body: { errorCode: "Unauthorized" }.to_json }, { status: 403 })

    assert_raises(Provider::Etoro::AuthenticationError) { @provider.fetch_balances }
    assert_raises(Provider::Etoro::AuthenticationError) { @provider.fetch_balances }
  end

  test "requires both keys" do
    assert_raises(Provider::Etoro::ConfigurationError) { Provider::Etoro.new(api_key: "key", user_key: "") }
  end

  test "reads every page of an instrument's daily candles, prices as eToro sent them" do
    window = { interval: "1d", from: "2026-01-05T00:00:00Z", to: "2026-10-24T00:00:00Z", limit: "2000" }
    first = stub_request(:get, "#{BASE}/data/instruments/3001/candles")
      .with(query: window)
      .to_return(status: 200, headers: JSON_HEADERS, body: candles_page(results: [ { time: "2026-10-22T21:00:00Z", close: "101.25" } ], next_cursor: "page-2"))
    second = stub_request(:get, "#{BASE}/data/instruments/3001/candles")
      .with(query: window.merge(cursor: "page-2"))
      .to_return(status: 200, headers: JSON_HEADERS, body: candles_page(results: [ { time: "2026-10-21T21:00:00Z", close: 100.5 } ]))

    candles = @provider.fetch_daily_candles(3001, from: Date.new(2026, 1, 5), to: Date.new(2026, 10, 24))

    assert_equal "ACME/USD", candles["symbol"]
    assert_equal [ "101.25", 100.5 ], candles["results"].map { |candle| candle["close"] }
    assert_requested first
    assert_requested second
  end

  test "asks for candles through the end of today when no end is given" do
    travel_to Time.utc(2026, 10, 24, 12)
    request = stub_request(:get, "#{BASE}/data/instruments/3001/candles")
      .with(query: { interval: "1d", from: "2026-10-12T00:00:00Z", to: "2026-10-25T00:00:00Z", limit: "2000" })
      .to_return(status: 200, headers: JSON_HEADERS, body: candles_page(results: []))

    assert_equal [], @provider.fetch_daily_candles(3001, from: Date.new(2026, 10, 12))["results"]
    assert_requested request
  end

  test "an unrecognised candles body is an error, not an empty history" do
    stub_request(:get, "#{BASE}/data/instruments/3001/candles")
      .with(query: hash_including({}))
      .to_return(status: 200, headers: JSON_HEADERS, body: { message: "maintenance" }.to_json)

    assert_raises(Provider::Etoro::ApiError) { @provider.fetch_daily_candles(3001, from: Date.new(2026, 1, 5)) }
  end

  test "reads an instrument's newest split-adjusted candles as one list" do
    request = stub_request(:get, "#{BASE}/market-data/instruments/3001/history/candles/desc/OneWeek/1000")
      .to_return(status: 200, headers: JSON_HEADERS, body: {
        interval: "OneWeek",
        candles: [ { instrumentId: 3001, candles: [
          { instrumentID: 3001, fromDate: "2026-10-18T21:00:00Z", close: 50.25 },
          { instrumentID: 3001, fromDate: "2026-10-11T21:00:00Z", close: 49.5 }
        ] } ]
      }.to_json)

    candles = @provider.fetch_adjusted_candles(3001, interval: "OneWeek")

    assert_equal [ "2026-10-18T21:00:00Z", "2026-10-11T21:00:00Z" ], candles.map { |candle| candle["fromDate"] }
    assert_equal [ 50.25, 49.5 ], candles.map { |candle| candle["close"] }
    assert_requested request
  end

  test "a 403 from the price endpoints is eToro withholding them for a while, not a rejected key" do
    forbidden = { status: 403, headers: JSON_HEADERS, body: { errorCode: "InsufficientPermissions" }.to_json }
    stub_request(:get, "#{BASE}/data/instruments/3001/candles").with(query: hash_including({})).to_return(forbidden)
    stub_request(:get, "#{BASE}/market-data/instruments/3001/history/candles/desc/OneDay/1000").to_return(forbidden)

    raw = assert_raises(Provider::Etoro::TransientError) { @provider.fetch_daily_candles(3001, from: Date.new(2026, 1, 5)) }
    adjusted = assert_raises(Provider::Etoro::TransientError) { @provider.fetch_adjusted_candles(3001, interval: "OneDay") }

    assert_equal [ 403, 403 ], [ raw.status_code, adjusted.status_code ]
  end

  test "the price endpoints wait out a rate limit" do
    stub_request(:get, "#{BASE}/market-data/instruments/3001/history/candles/desc/OneDay/1000")
      .to_return(
        { status: 429, headers: { "Retry-After" => "7" } },
        { status: 200, headers: JSON_HEADERS, body: { interval: "OneDay", candles: [ { instrumentId: 3001, candles: [] } ] }.to_json }
      )

    @provider.expects(:sleep).with(7).once

    assert_equal [], @provider.fetch_adjusted_candles(3001, interval: "OneDay")
  end

  test "the price endpoints retry an outage, then give up with a transient error" do
    stub_request(:get, "#{BASE}/data/instruments/3001/candles").with(query: hash_including({})).to_return(status: 503)

    @provider.expects(:sleep).with(2).once
    @provider.expects(:sleep).with(4).once

    error = assert_raises(Provider::Etoro::TransientError) { @provider.fetch_daily_candles(3001, from: Date.new(2026, 1, 5)) }
    assert_equal 503, error.status_code
  end

  test "price requests to one of eToro's quotas are spaced apart" do
    stub_request(:get, %r{\A#{Regexp.escape(BASE)}/market-data/instruments/300[12]/history/candles/desc/OneDay/1000\z})
      .to_return(status: 200, headers: JSON_HEADERS, body: { interval: "OneDay", candles: [] }.to_json)

    @provider.expects(:sleep).with { |seconds| seconds.positive? && seconds <= Provider::Etoro::PRICE_REQUEST_INTERVAL }.once

    @provider.fetch_adjusted_candles(3001, interval: "OneDay")
    @provider.fetch_adjusted_candles(3002, interval: "OneDay")
  end

  private

    def candles_page(results:, next_cursor: nil)
      {
        instrumentId: 3001,
        symbol: "ACME/USD",
        interval: "1d",
        side: "bid",
        pagination: { limit: 2000, hasNext: next_cursor.present?, nextCursor: next_cursor },
        results: results
      }.to_json
    end

    def fetch_history
      @provider.fetch_balance_history(account_type: "Trading", account_id: "acc-1", from_date: Date.new(2025, 10, 25), to_date: Date.new(2026, 10, 24))
    end
end
