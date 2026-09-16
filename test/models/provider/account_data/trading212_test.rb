require "test_helper"

class Provider::AccountData::Trading212Test < ActiveSupport::TestCase
  setup do
    @client = mock("Trading 212 transport")
    @observed_at = Time.utc(2026, 2, 15, 12)
    @adapter = adapter
    @account = Ingestion::Record.account(external_id: "account_1", name: "Trading 212", currency: "USD")
  end

  test "factory uses explicit credentials environment and family currency fallback" do
    Provider::Trading212.expects(:new).with(api_key: "key", api_secret: "secret", environment: "demo").returns(@client)
    built = Provider::AccountData::Trading212.build(credentials: { api_key: "key", api_secret: "secret" }, settings: {}, context: {
      environment: "demo", family_currency: "CAD", timezone: "America/Toronto", observed_at: @observed_at,
      trading212_instrument_catalog: { "format" => Provider::AccountData::Trading212::InstrumentCatalog::FORMAT,
        "source" => nil, "availability" => "absent", "instruments" => [] }
    })

    assert_equal "CAD", built.normalize_account(summary)[:currency]
    refute Provider::AccountData::Trading212.native_ready?
    assert_equal %w[holdings activities], Provider::AccountData::Trading212.definition.capabilities
  end

  test "summary retains total free and reserved cash with an explicit current balance anchor" do
    record = @adapter.normalize_account(summary)

    assert_equal "account_1", record[:external_id]
    assert_equal BigDecimal("2000.123456789012345678"), record[:balance]
    assert_equal BigDecimal("100.12"), record[:cash_balance]
    assert_equal BigDecimal("5"), record[:reserved_balance]
    assert_equal true, record[:metadata][:balance_policy][:current_anchor]
  end

  test "position identity valuation cost basis and ticker lookup preserve existing holdings" do
    record = @adapter.normalize_position(position, account: @account)

    assert_equal "trading212_position_account_1_AAPL_US_EQ_2026-02-15", record[:external_id]
    assert_equal BigDecimal("2.123456789012345678"), record[:quantity]
    assert_equal BigDecimal("2.123456789012345678") * BigDecimal("175.12"), record[:amount]
    assert_equal BigDecimal("150.1234"), record[:metadata][:cost_basis]
    assert_equal false, record[:metadata][:delete_future_holdings]
    assert_equal({ ticker: "AAPL", name: "Apple Inc.", lookup: "ticker_only" }, record[:security])
    refute record[:security].key?(:isin)
  end

  test "holdings use the fixed family observation date rather than the replay date" do
    record = adapter(observed_at: Time.utc(2026, 2, 15, 2)).normalize_position(position, account: @account)

    assert_equal Date.new(2026, 2, 14), record[:date]
    assert record[:external_id].end_with?("2026-02-14")
  end

  test "buy and sell activities retain filled IDs quantity signs and wallet net amounts" do
    buy = @adapter.normalize_order(order, account: @account)
    sell = @adapter.normalize_order(order(side: "SELL", net_value: "-348.52"), account: @account)

    assert_equal "trading212_order_fill_1", buy[:external_id]
    assert_equal "buy", buy[:activity_type]
    assert_equal BigDecimal("2"), buy[:quantity]
    assert_equal BigDecimal("350.24"), buy[:amount]
    assert_equal "sell", sell[:activity_type]
    assert_equal BigDecimal("-2"), sell[:quantity]
    assert_equal BigDecimal("-348.52"), sell[:amount]
    assert_equal "Sell", sell[:metadata][:investment_activity_label]
  end

  test "order fallback identity value and instrument currency remain explicit" do
    raw = order
    raw[:fill].delete(:id)
    raw[:fill].delete(:walletImpact)
    raw[:order][:filledValue] = "355"
    raw[:order][:instrument][:currency] = "EUR"
    record = @adapter.normalize_order(raw, account: @account)
    raw[:order].delete(:filledValue)
    calculated = @adapter.normalize_order(raw, account: @account)

    assert_equal "trading212_order_order_1", record[:external_id]
    assert_equal BigDecimal("355"), record[:amount]
    assert_equal BigDecimal("350.24"), calculated[:amount]
    assert_equal "EUR", record[:currency]
  end

  test "dividends retain cash amount activity label and optional security enrichment" do
    record = @adapter.normalize_dividend(dividend, account: @account)
    cash_only = @adapter.normalize_dividend(dividend(ticker: nil), account: @account)

    assert_equal "trading212_dividend_div_1", record[:external_id]
    assert_equal "dividend", record[:activity_type]
    assert_equal BigDecimal("-25.12"), record[:amount]
    assert_equal "Dividend from AAPL", record[:name]
    assert_equal "USD", record[:currency]
    assert_equal "AAPL", record[:security][:ticker]
    assert_equal "50", record[:metadata][:extra][:trading212][:quantity]
    assert_equal "0.5024", record[:metadata][:extra][:trading212][:gross_amount_per_share]
    assert_equal "Dividend", cash_only[:name]
    assert_nil cash_only[:security]
  end

  test "every supported cash activity has the same legacy sign and label" do
    { "DEPOSIT" => [ "contribution", "Contribution", -10 ], "WITHDRAW" => [ "withdrawal", "Withdrawal", 10 ],
      "INTEREST" => [ "interest", "Interest", -10 ], "INTEREST_ON_FREE_CASH" => [ "interest", "Interest", -10 ],
      "FEE" => [ "fee", "Fee", 10 ] }.each do |type, (kind, label, amount)|
      record = @adapter.normalize_cash_transaction(cash(type: type, amount: "-10"), account: @account)
      assert_equal kind, record[:activity_type]
      assert_equal label, record[:metadata][:investment_activity_label]
      assert_equal BigDecimal(amount.to_s), record[:amount]
      assert_equal "trading212_transaction_cash_1", record[:external_id]
    end
  end

  test "non-filled orders empty positions zero cash and unsupported cash types are omitted" do
    pending_order = order
    pending_order[:order][:status] = "PENDING"

    assert_nil @adapter.normalize_order(pending_order, account: @account)
    assert_nil @adapter.normalize_position(position(quantity: "0"), account: @account)
    assert_nil @adapter.normalize_cash_transaction(cash(amount: "0"), account: @account)
    assert_nil @adapter.normalize_cash_transaction(cash(type: "UNKNOWN"), account: @account)
  end

  test "activity phases and provider continuations do not complete before all history arrives" do
    @client.expects(:fetch_orders_page).with(cursor: nil).returns(page([ order ], next_cursor: "orders-2"))
    first = @adapter.fetch_activities(account: @account)
    @client.expects(:fetch_orders_page).with(cursor: "orders-2").returns(page([]))
    second = @adapter.fetch_activities(account: @account, cursor: first.next_cursor)
    @client.expects(:fetch_instruments_page).returns(page([]))
    @client.expects(:fetch_dividends_page).with(cursor: nil).returns(page([ dividend ]))
    third = @adapter.fetch_activities(account: @account, cursor: second.next_cursor)
    @client.expects(:fetch_transactions_page).with(cursor: nil).returns(page([ cash ]))
    last = @adapter.fetch_activities(account: @account, cursor: third.next_cursor)

    [ first, second, third ].each do |result|
      refute result.complete?
      assert_equal result.next_cursor, result.progress_cursor
      assert_nil result.checkpoint_cursor
    end
    assert last.complete?
    assert last.checkpoint_cursor
    assert_nil last.progress_cursor
    assert_equal "all_history", last.coverage["scope"]
  end

  test "missing activity dates retain the captured fallback date after resumable progress" do
    @client.expects(:fetch_orders_page).returns(page([]))
    first = @adapter.fetch_activities(account: @account)
    resumed = adapter(observed_at: @observed_at + 1.day)
    @client.expects(:fetch_instruments_page).returns(page([]))
    @client.expects(:fetch_dividends_page).returns(page([ dividend(paidOn: nil) ]))

    page = resumed.fetch_activities(account: @account, cursor: first.progress_cursor)

    assert_equal Date.new(2026, 2, 15), page.records.first[:date]
    assert_equal @observed_at.iso8601(9), page.coverage["end"]
  end

  test "instrument errors use supplied cached names and surface a partial enrichment warning" do
    adapter = adapter(cached_instruments: [ { ticker: "AAPL_US_EQ", shortName: "Cached Apple" } ])
    @client.expects(:fetch_orders_page).returns(page([]))
    first = adapter.fetch_activities(account: @account)
    @client.expects(:fetch_instruments_page).raises(Provider::Trading212::ApiError.new("Unavailable"))
    @client.expects(:fetch_dividends_page).returns(page([ dividend ]))

    result = adapter.fetch_activities(account: @account, cursor: first.next_cursor)

    assert_equal "Cached Apple", result.records.first[:security][:name]
    assert_equal "instrument_catalog_unavailable_cached_metadata_used", result.warnings.first["code"]
  end

  test "raw response evidence is retained without copying private fields to normalized metadata" do
    @client.expects(:fetch_positions_page).returns(page([ position ]).merge(evidence: { positions: [ position ], owner: "private-owner" }))

    result = @adapter.fetch_holdings(account: @account)

    assert_equal "private-owner", result.evidence["response"][:owner]
    refute_includes result.records.first[:metadata].inspect, "private-owner"
    refute_includes result.inspect, "private-owner"
  end

  test "malformed financial data and unknown continuations fail with sanitized errors" do
    [ -> { @adapter.normalize_account(summary.merge(totalValue: nil)) },
      -> { @adapter.normalize_position(position(quantity: 2.5), account: @account) },
      -> { @adapter.normalize_dividend(dividend(paidOn: "private-date"), account: @account) },
      -> { @adapter.normalize_cash_transaction(cash(reference: nil), account: @account) },
      -> { @adapter.fetch_activities(account: @account, cursor: "not-json") } ].each do |operation|
      error = assert_raises(Provider::AccountData::InvalidResponse, &operation)
      assert_nil error.cause
      refute_includes error.message, "private-date"
    end
  end

  private
    def adapter(**options)
      Provider::AccountData::Trading212.new(**{ client: @client, currency: "USD", timezone: "America/New_York", observed_at: @observed_at }.merge(options))
    end

    def page(items, next_cursor: nil)
      { items: items, next_cursor: next_cursor, evidence: items }
    end

    def summary
      { id: "account_1", totalValue: "2000.123456789012345678", cash: { availableToTrade: "100.12", reservedForOrders: "5" } }
    end

    def position(**options)
      { instrument: { ticker: "AAPL_US_EQ", name: "Apple Inc.", isin: "US0378331005", currency: "USD" },
        quantity: "2.123456789012345678", currentPrice: "175.12", averagePricePaid: "150.1234" }.merge(options)
    end

    def order(side: "BUY", net_value: "-350.24")
      { order: { id: "order_1", status: "FILLED", side: side, instrument: { ticker: "AAPL_US_EQ", name: "Apple Inc.", currency: "USD" }, createdAt: "2026-02-14T12:00:00Z" },
        fill: { id: "fill_1", quantity: "2", price: "175.12", filledAt: "2026-02-14T12:00:00Z", walletImpact: { netValue: net_value } } }
    end

    def dividend(**options)
      { reference: "div_1", ticker: "AAPL_US_EQ", amount: "25.12", paidOn: "2026-02-14", quantity: "50", grossAmountPerShare: "0.5024", type: "ORDINARY" }.merge(options)
    end

    def cash(**options)
      { reference: "cash_1", type: "DEPOSIT", amount: "1000", dateTime: "2026-02-14T12:00:00Z" }.merge(options)
    end
end
