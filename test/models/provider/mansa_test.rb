require "test_helper"

class Provider::MansaTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Mansa.new("test_api_key")
    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
  end

  # Fixture bodies below are copies of real responses captured against the
  # live API (2026-09-17), not guessed — see Provider::Mansa's class comment
  # for why that matters here specifically.

  test "search_securities maps fields from a real NGX response" do
    body = {
      success: true,
      data: [
        {
          ticker: "MTNN",
          name: "MTN Nigeria Communications Plc",
          exchange: "NGX",
          exchange_code: "NIGERIA",
          currency: "NGN",
          sector: "ICT",
          price: 815,
          change: 0,
          change_pct: 0,
          volume: 1696945,
          last_updated: "2026-09-17T16:25:50.197+00:00"
        }
      ],
      meta: { query: "MTN", count: 1, source: "mansa_api" }
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("MTN", exchange_operating_mic: "XNSA")

    assert result.success?
    security = result.data.first
    assert_equal "MTNN", security.symbol
    # Real field is `name`, not `company_name` — the first draft of this
    # provider guessed `company_name` from the docs alone and got it wrong.
    assert_equal "MTN Nigeria Communications Plc", security.name
    assert_equal "XNSA", security.exchange_operating_mic
    assert_equal "NGN", security.currency
  end

  test "search_securities searches every exchange when no MIC is given, matching the real controller call" do
    # Sure's trade-form combobox never passes exchange_operating_mic on search
    # (see app/views/trades/_form.html.erb).
    body = {
      success: true,
      data: [
        { ticker: "MTNN", name: "MTN Nigeria Communications Plc", exchange: "NGX", currency: "NGN" },
        { ticker: "MTN", name: "MTN Group Ltd", exchange: "JSE", currency: "ZAR" },
        { ticker: "MTNZ", name: "MTN Zambia", exchange: "LuSE", currency: "ZMW" }
      ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    fake_request = Struct.new(:params).new({})
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).yields(fake_request).returns(mock_response)

    result = @provider.search_securities("MTN")

    assert result.success?
    assert_not fake_request.params.key?("exchange")
    assert_equal %w[XNSA XJSE XLUS], result.data.map(&:exchange_operating_mic)
    assert_equal %w[NG ZA ZM], result.data.map(&:country_code)
  end

  test "search_securities keeps listing countries for combobox searches without an exchange" do
    stub_search_response(
      { ticker: "MTNN", name: "MTN Nigeria Communications Plc", exchange: "NGX", currency: "NGN" },
      { ticker: "MTN", name: "MTN Group Ltd", exchange: "JSE", currency: "ZAR" }
    )

    assert_equal %w[NG ZA], @provider.search_securities("MTN", country_code: "US").data.map(&:country_code)
  end

  test "search_securities blanks the country only for a cross-border search naming an exchange" do
    stub_search_response({ ticker: "MTNN", name: "MTN Nigeria Communications Plc", exchange: "NGX", currency: "NGN" })

    search = ->(country) { @provider.search_securities("MTNN", exchange_operating_mic: "XNSA", country_code: country).data.first.country_code }

    assert_equal "NG", search.call("NG")
    assert_equal "NG", search.call("ng")
    assert_equal "NG", search.call(nil)
    assert_nil search.call("US")
  end

  test "a typed ticker without an exchange does not resolve to a listing in another country" do
    stub_search_response({ ticker: "MTNT", name: "MTN Typed", exchange: "NGX", currency: "NGN" })
    Security.stubs(:providers).returns([ @provider ])

    resolved = Security::Resolver.new("MTNT", country_code: "US").resolve

    assert resolved.offline?
    assert_nil resolved.exchange_operating_mic
  end

  test "a family in another country can resolve a listing without taking it offline" do
    existing = Security.create!(ticker: "MTNN", exchange_operating_mic: "XNSA", country_code: "NG", price_provider: "mansa")
    stub_search_response({ ticker: "MTNN", name: "MTN Nigeria Communications Plc", exchange: "NGX", currency: "NGN" })
    Security.stubs(:providers).returns([ @provider ])
    Setting.stubs(:enabled_securities_providers).returns([ "mansa" ])

    resolved = Security::Resolver.new(
      "MTNN",
      exchange_operating_mic: "XNSA",
      country_code: "US",
      price_provider: "mansa"
    ).resolve

    assert_equal existing, resolved
    assert_not resolved.reload.offline?
    assert_equal "mansa", resolved.price_provider
  end

  test "search_securities scopes to the Mansa exchange for an explicit MIC" do
    body = {
      success: true,
      data: [ { ticker: "MTN", name: "MTN Group Ltd", exchange: "JSE", currency: "ZAR" } ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    fake_request = Struct.new(:params).new({})
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).yields(fake_request).returns(mock_response)

    result = @provider.search_securities("MTN", exchange_operating_mic: "XJSE")

    assert result.success?
    assert_equal "JSE", fake_request.params["exchange"]
    assert_equal "XJSE", result.data.first.exchange_operating_mic
  end

  test "search_securities returns nothing for an explicit MIC Mansa doesn't cover" do
    # An explicit MIC we can't map (e.g. a caller checking a NYSE-listed
    # security while Mansa happens to be enabled) must not broaden to an
    # unscoped search and return unrelated results.
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).never

    @provider.expects(:enforce_daily_limit!).never

    result = @provider.search_securities("AAPL", exchange_operating_mic: "XNYS")

    assert result.success?
    assert_equal [], result.data
  end

  test "search_securities drops a result on an exchange this adapter can't map to a real MIC" do
    # A result from an exchange Mansa adds later must never get saved with
    # Mansa's own exchange code standing in for a real ISO MIC.
    body = {
      success: true,
      data: [
        { ticker: "SOMETICKER", name: "Some New Exchange Company", exchange: "NEWX", currency: "USD" }
      ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("Some New Exchange Company")

    assert result.success?
    assert_equal [], result.data
  end

  test "fetch_security_price rejects an explicit MIC Mansa doesn't cover, rather than mislabeling an NGX quote" do
    # The actual bug this guards: without this check, a present-but-unmapped
    # MIC would silently fetch NGX's quote and let the caller stamp it with
    # whatever exchange was actually asked for — a real, wrong security price
    # under someone else's exchange label.
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).never

    @provider.expects(:enforce_daily_limit!).never

    result = @provider.fetch_security_price(symbol: "AAPL", exchange_operating_mic: "XNYS", date: Date.current)

    assert_not result.success?
    assert_instance_of Provider::Mansa::Error, result.error
    assert_match(/does not support exchange XNYS/, result.error.message)
  end

  test "fetch_security_price requires a MIC rather than guessing an exchange" do
    @provider.expects(:enforce_daily_limit!).never
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).never

    result = @provider.fetch_security_price(symbol: "MTNN", exchange_operating_mic: nil, date: Date.current)

    assert_not result.success?
    assert_match(/requires an exchange/, result.error.message)
  end

  test "fetch_security_price requests the quote from the security's own Mansa exchange" do
    body = {
      success: true,
      data: { ticker: "ZCCM", name: "ZCCM Investments Holdings", price: 92.5 },
      meta: { exchange: "LuSE", currency: "ZMW" }
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get)
      .with("https://mansaapi.com/api/v1/markets/exchanges/LuSE/stocks/ZCCM")
      .returns(mock_response)

    result = @provider.fetch_security_price(symbol: "ZCCM", exchange_operating_mic: "XLUS", date: Date.current)

    assert result.success?
    assert_equal "ZMW", result.data.currency
    assert_equal "XLUS", result.data.exchange_operating_mic
  end

  test "fetch_security_price reads currency from meta, not data" do
    body = {
      success: true,
      data: {
        ticker: "MTNN",
        name: "MTN Nigeria Communications Plc",
        price: 815,
        change: 0,
        change_pct: 0,
        volume: 1696945,
        market_cap: 15914634558074,
        shares_outstanding: 20995560103,
        sector: "ICT",
        logo_url: nil,
        last_updated: "2026-09-17T16:25:50.197+00:00"
        # Note: no "currency" key here on purpose — see meta below.
      },
      meta: {
        exchange: "NGX",
        currency: "NGN",
        price_unit: "major",
        updated_at: "2026-09-17T16:25:50.197+00:00",
        data_freshness: "30_minutes",
        source: "mansa_api"
      }
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_security_price(symbol: "MTNN", exchange_operating_mic: "XNSA", date: Date.current)

    assert result.success?
    price = result.data
    assert_equal 815, price.price
    # This is the actual bug the first draft had: reading `data.currency`
    # (which doesn't exist on this endpoint) instead of `meta.currency`.
    assert_equal "NGN", price.currency
    assert_equal "XNSA", price.exchange_operating_mic
  end

  test "fetch_security_price rejects a non-today date (free tier has no historical endpoint)" do
    result = @provider.fetch_security_price(symbol: "MTNN", exchange_operating_mic: "XNSA", date: 5.days.ago.to_date)

    assert_not result.success?
    # Only RateLimitError survives with_provider_response's default error
    # transformer as its own subclass (see Provider::RateLimitable) — every
    # other raised error, including this one, normalizes to the base Error
    # class with its message preserved. Consistent with every other provider
    # in this codebase, not a Mansa-specific gap.
    assert_instance_of Provider::Mansa::Error, result.error
    assert_match(/free tier only exposes the current quote/, result.error.message)
  end

  test "fetch_security_prices raises clearly for a range that doesn't include today" do
    result = @provider.fetch_security_prices(
      symbol: "MTNN",
      exchange_operating_mic: "XNSA",
      start_date: 10.days.ago.to_date,
      end_date: 5.days.ago.to_date
    )

    assert_not result.success?
    assert_match(/Pro plan required/, result.error.message)
  end

  test "fetch_security_prices returns today's quote as a best-effort single row when range includes today" do
    body = {
      success: true,
      data: { ticker: "MTNN", name: "MTN Nigeria Communications Plc", price: 815 },
      meta: { exchange: "NGX", currency: "NGN" }
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_security_prices(
      symbol: "MTNN",
      exchange_operating_mic: "XNSA",
      start_date: 5.days.ago.to_date,
      end_date: Date.current
    )

    assert result.success?
    assert_equal 1, result.data.length
    assert_equal Date.current, result.data.first.date
  end

  test "check_api_error! extracts the nested error message, not a raw hash dump" do
    body = {
      success: false,
      error: {
        code: "NOT_FOUND",
        message: "Ticker 'NOTAREALTICKER' not found on NGX.",
        hint: "Check the ticker against GET /api/v1/markets/exchanges/NGX/stocks",
        docs: "https://mansaapi.com/docs/markets"
      }
    }.to_json

    error = assert_raises(Provider::Mansa::Error) do
      @provider.send(:check_api_error!, JSON.parse(body))
    end

    # The first draft interpolated the whole error hash into the message
    # (`#{parsed["error"]}` where "error" is itself a Hash) instead of
    # pulling out just the message string.
    assert_match(/Ticker 'NOTAREALTICKER' not found on NGX\./, error.message)
    assert_match(/NOT_FOUND/, error.message)
    assert_no_match(/=>/, error.message) # would appear in a raw Hash#to_s dump
  end

  private
    def stub_search_response(*listings)
      mock_response = mock
      mock_response.stubs(:body).returns({ success: true, data: listings }.to_json)
      @provider.stubs(:client).returns(mock_client = mock)
      mock_client.stubs(:get).returns(mock_response)
    end
end
