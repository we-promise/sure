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

  test "search_securities always scopes to NGX even with no MIC given, matching the real controller call" do
    # Sure's actual trade-form combobox never passes exchange_operating_mic on
    # search (see app/views/trades/_form.html.erb) — this test calls the
    # provider exactly that way, which the original PR's only search test
    # didn't (it passed exchange_operating_mic: "XNSA" explicitly and so
    # never exercised the real controller -> provider path).
    body = {
      success: true,
      data: [
        { ticker: "MTNN", name: "MTN Nigeria Communications Plc", exchange: "NGX", currency: "NGN" }
      ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    fake_request = Struct.new(:params).new({})
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).yields(fake_request).returns(mock_response)

    result = @provider.search_securities("MTNN")

    assert result.success?
    # The actual bug: without this, an unscoped search could return matches
    # from other African exchanges this adapter has no verified MIC for.
    assert_equal "NGX", fake_request.params["exchange"]
    assert_equal "XNSA", result.data.first.exchange_operating_mic
  end

  test "search_securities drops a result on an exchange this adapter can't map to a real MIC" do
    # Defensive: even though the request above always explicitly scopes to a
    # single exchange, this proves a stray result from an unmapped exchange
    # (e.g. Mansa's search broadening the filter) never gets saved with
    # Mansa's own exchange code standing in for a real ISO MIC.
    body = {
      success: true,
      data: [
        { ticker: "SOMETICKER", name: "Some Johannesburg Company", exchange: "JSE", currency: "ZAR" }
      ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("Some Johannesburg Company", exchange_operating_mic: "XNSA")

    assert result.success?
    assert_equal [], result.data
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
end
