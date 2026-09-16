require "test_helper"

class Provider::AccountData::TradeRepublicTest < ActiveSupport::TestCase
  setup do
    @client = mock("Trade Republic bounded reader")
    @adapter = adapter
    @portfolio = @adapter.normalize_account(account_row, kind: "portfolio")
    @cash = @adapter.normalize_account(account_row, kind: "cash")
  end

  test "one session exposes stable portfolio and cash identities without invented balances" do
    @client.expects(:get_account).returns(account_row)
    page = @adapter.list_accounts
    assert_equal [ "DE123", "cash:DE123" ], page.records.map { |record| record[:external_id] }
    assert_equal [ "Investment", "Depository" ], page.records.map { |record| record[:account_type] }
    assert page.records.all? { |record| record[:balance].nil? && record[:metadata][:balance_provided] == false }
    assert_equal "DE123", page.records.first[:sensitive_details][:securities_account_number]
    assert_equal account_row, page.evidence["response"]
    refute Provider::AccountData::TradeRepublic.native_ready?
  end

  test "currency falls back explicitly and malformed currencies are rejected" do
    instance = adapter(currency: "GBP")
    assert_equal "GBP", instance.normalize_account(account_row.except(:currency), kind: "cash")[:currency]
    assert_raises(Provider::AccountData::InvalidResponse) { instance.normalize_account(account_row.merge(currency: "XYZ"), kind: "cash") }
  end

  test "available cash takes precedence and keeps provider sign" do
    @client.expects(:get_cash).returns(account: account_row, cash: { amount: "100" }, available_cash: { amount: "-12.34567890123456789" })
    page = @adapter.fetch_balance(account: @cash)
    assert_equal BigDecimal("-12.34567890123456789"), page.records.first[:balance]
    assert_equal page.records.first[:balance], page.records.first[:cash_balance]
    assert page.records.first[:metadata][:balance_policy][:current_anchor]
  end

  test "missing or malformed cash cannot silently replace the balance with zero" do
    [ nil, "invalid", 1.25 ].each do |value|
      @client.expects(:get_cash).returns(account: account_row, cash: { amount: value }, available_cash: nil)
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: @cash) }
    end
  end

  test "cash and portfolio responses are bound to the linked source account and currency" do
    [ account_row.merge(securitiesAccountNumber: "OTHER"), account_row.merge(currency: "USD") ].each do |row|
      @client.expects(:get_cash).returns(account: row, cash: { amount: "1" }, available_cash: nil)
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: @cash) }
    end
  end

  test "portfolio total is exact position value and excludes cash" do
    stub_portfolio
    @client.expects(:get_price).with(instrument_id: "US0378331005", category_type: "stocksAndETFs")
      .returns(account: account_row, price: "100.125", attempts: [])
    page = @adapter.fetch_balance(account: @portfolio)
    assert_equal BigDecimal("250.3125"), page.records.first[:balance]
    assert_equal BigDecimal("0"), page.records.first[:cash_balance]
  end

  test "known total remains unchanged when a current quote is missing even if an old quote is supplied" do
    instance = adapter(cached_positions: { "DE123" => [ { isin: "US0378331005", price: "100" } ] })
    account = Ingestion::Record.account(**@portfolio.attributes.merge(balance: BigDecimal("700")))
    stub_portfolio
    @client.expects(:get_price).returns(account: account_row, price: nil, attempts: [])
    page = instance.fetch_balance(account: account)
    assert_equal BigDecimal("700"), page.records.first[:balance]
    assert_equal BigDecimal("700"), page.evidence["fallback_balance"]
    assert_equal "100", page.evidence["cached_prices"]["US0378331005"]
    assert_equal "position_price_unavailable", page.warnings.first["code"]
  end

  test "an empty complete portfolio has zero value" do
    @client.expects(:get_portfolio).returns(account: account_row, portfolio: { categories: [] })
    @client.expects(:get_price).never
    assert_equal BigDecimal("0"), @adapter.fetch_balance(account: @portfolio).records.first[:balance]
  end

  test "holdings preserve exact daily identity cost basis and ISIN ticker lookup" do
    record = @adapter.normalize_holding(position, account: @portfolio)
    assert_equal "trade_republic_position_DE123_US0378331005_2026-09-14", record[:external_id]
    assert_equal BigDecimal("250.3125"), record[:amount]
    assert_equal BigDecimal("90.25"), record[:metadata][:cost_basis]
    assert_equal "ticker_only", record[:security][:lookup]
    assert_equal "US0378331005", record[:security][:ticker]
    refute record[:metadata][:delete_future_holdings]
  end

  test "captured family date determines the daily holding identity" do
    instance = adapter(timezone: "America/Los_Angeles", observed_at: Time.utc(2026, 9, 15, 1))
    assert_equal Date.new(2026, 9, 14), instance.normalize_holding(position, account: @portfolio)[:date]
  end

  test "cash partition never receives holdings" do
    @client.expects(:get_portfolio).never
    assert_empty @adapter.fetch_holdings(account: @cash).records
  end

  test "partial quotes preserve evidence and never claim an authoritative completed snapshot" do
    stub_portfolio
    @client.expects(:get_price).returns(account: account_row, price: nil, attempts: [ { status: "timeout" } ])
    page = @adapter.fetch_holdings(account: @portfolio)
    refute page.complete?
    refute page.coverage["absence_authoritative"]
    assert_empty page.records
    assert_equal "timeout", page.evidence["quotes"]["US0378331005"]["attempts"].first["status"]
  end

  test "duplicate financial position identities are rejected rather than overwritten" do
    stub_portfolio(positions: [ raw_position, raw_position ])
    @client.expects(:get_price).once.returns(account: account_row, price: "100", attempts: [])
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_holdings(account: @portfolio) }
  end

  test "buy and sell preserve signed quantity opposite cash sign and embedded charges" do
    buy = @adapter.normalize_activity(event(detail: trade_detail), account: @portfolio)
    sell = @adapter.normalize_activity(event(detail: trade_detail.merge(quantity: "-2.5")), account: @portfolio)
    assert_equal BigDecimal("-251"), buy[:amount]
    assert_equal BigDecimal("2.5"), buy[:quantity]
    assert_equal BigDecimal("100.4"), buy[:price]
    assert_equal BigDecimal("251"), sell[:amount]
    assert_equal BigDecimal("-2.5"), sell[:quantity]
    assert_equal "Sell", sell[:metadata][:investment_activity_label]
    assert_equal "1.00", buy[:metadata][:extra][:trade_republic][:fees]
    refute buy[:metadata].key?(:fee)
    assert_equal "trade", buy.ledger_type
  end

  test "missing trade amount derives only from an explicit price" do
    record = @adapter.normalize_activity(event(detail: trade_detail.merge(amount: nil, price: "184")), account: @portfolio)
    assert_equal BigDecimal("-460"), record[:amount]
    assert_nil @adapter.normalize_activity(event(detail: trade_detail.merge(amount: nil)), account: @portfolio)
  end

  test "cash category governs direction regardless of provider signed amount" do
    record = @adapter.normalize_activity(event(category: "PAYMENT_RECEIVED", detail: { amount: "500", signed_amount: "500", currency: "EUR" }), account: @cash)
    assert_equal BigDecimal("-500"), record[:amount]
    assert_equal "Contribution", record[:metadata][:investment_activity_label]
    assert_equal "transaction", record.ledger_type
  end

  test "legacy CARD_CASH_BACK purchase is corrected to an expense" do
    record = @adapter.normalize_activity(event(category: "PAYMENT_RECEIVED", eventType: "CARD_CASH_BACK", title: "Marktkauf",
      detail: { amount: "204.18", signed_amount: "-204.18" }), account: @cash)
    assert_equal BigDecimal("204.18"), record[:amount]
    assert_equal "Card payment", record[:metadata][:investment_activity_label]
    assert_equal "Marktkauf", record[:name]
  end

  test "transfers retain movement classification and cash detail metadata" do
    record = @adapter.normalize_activity(event(category: "PAYMENT_RECEIVED", eventType: "INCOMING_TRANSFER", subtitle: "From savings", detail: { amount: "25", reference: "memo" }), account: @cash)
    assert_equal "funds_movement", record[:metadata][:kind]
    assert_equal "From savings", record[:metadata][:notes]
    assert_equal "memo", record[:metadata][:extra][:trade_republic][:provider_detail][:reference]
  end

  test "cash linkage snapshot controls the portfolio partition without deleting entries" do
    raw = event(category: "PAYMENT_RECEIVED", detail: { amount: "25" })
    assert @adapter.normalize_activity(raw, account: @portfolio)
    instance = adapter(linked_cash_ids: [ "cash:DE123" ])
    assert_nil instance.normalize_activity(raw, account: @portfolio)
    assert instance.normalize_activity(raw, account: @cash)
    assert_nil instance.normalize_activity(event(detail: trade_detail), account: @cash)
  end

  test "unknown events stay unmapped and missing trade detail produces no guessed cash" do
    assert_nil @adapter.normalize_activity(event(category: "new_category", detail: { amount: "25" }), account: @portfolio)
    assert_nil @adapter.normalize_activity(event, account: @portfolio)
  end

  test "native Float money is rejected and legacy conversion is explicit and nonmutating" do
    raw = event(detail: trade_detail.merge(quantity: 2.5, amount: 251.0, fees: 1.0))
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw, account: @portfolio) }
    record = @adapter.normalize_legacy_activity(raw, account: @portfolio)
    assert_equal BigDecimal("-251"), record[:amount]
    assert_equal 251.0, raw[:detail][:amount]
    holding = position.merge(price: 100.125)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_holding(holding, account: @portfolio) }
    assert_equal BigDecimal("250.3125"), @adapter.normalize_legacy_holding(holding, account: @portfolio)[:amount]
  end

  test "timeline capture binds detail responses to the same account" do
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(account: account_row, response: { items: [ timeline_item ] }, next_cursor: nil)
    @client.expects(:get_event_detail).with(event_id: "event-1").returns(account: account_row.merge(securitiesAccountNumber: "OTHER"), response: {})
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.capture_timeline_page(topic: "timelineTransactions") }
  end

  test "raw German event details produce an exact trade with captured evidence" do
    capture = captured_page(items: [ timeline_item ], details: { "event-1" => detail_response })
    page = @adapter.normalize_timeline_page(capture: capture, account: @portfolio)
    record = page.records.first
    assert_equal BigDecimal("2.5"), record[:quantity]
    assert_equal BigDecimal("-1234.56"), record[:amount]
    assert_equal "US0378331005", record[:security][:ticker]
    assert_equal BigDecimal("1.25"), BigDecimal(record[:metadata][:extra][:trade_republic][:fees])
    refute page.complete?
    assert_nil page.checkpoint_cursor
    assert_nil page.next_cursor
    assert_equal "timelineTransactions", page.evidence["capture"]["topic"]
  end

  test "English grouped decimals and share removal direction are normalized" do
    raw = detail_response.deep_dup
    raw[:sections][0][:data][0] = { title: "Shares removed", detail: { text: "2.5" } }
    raw[:sections][0][:data][1] = { title: "Total", detail: { value: { text: "1,234.56 EUR", currency: "EUR" } } }
    capture = captured_page(items: [ timeline_item ], details: { "event-1" => raw })
    record = @adapter.normalize_timeline_page(capture: capture, account: @portfolio).records.first
    assert_equal BigDecimal("-2.5"), record[:quantity]
    assert_equal BigDecimal("1234.56"), record[:amount]
  end

  test "missing captured detail cannot advance a timeline checkpoint" do
    assert_raises(Provider::AccountData::IncompletePage) do
      @adapter.normalize_timeline_page(capture: captured_page(items: [ timeline_item ], details: {}), account: @portfolio)
    end
  end

  test "per-account activities cannot bypass the dual-topic and partition barrier" do
    @client.expects(:get_timeline_page).never
    assert_raises(Provider::AccountData::UnsupportedCapability) { @adapter.fetch_activities(account: @portfolio) }
  end

  test "localized cash labels and trade names keep canonical trade activity labels" do
    instance = adapter(locale: "de")
    cash = instance.normalize_activity(event(category: "PAYMENT_RECEIVED", detail: { amount: "25" }), account: @cash)
    trade = instance.normalize_activity(event(detail: trade_detail), account: @portfolio)
    assert_equal I18n.t("trade_republic_items.activities.labels.contribution", locale: :de), cash[:metadata][:investment_activity_label]
    assert_equal "Buy", trade[:metadata][:investment_activity_label]
    assert trade[:name].start_with?(I18n.t("trade_republic_items.activities.labels.buy", locale: :de))
  end

  test "detail capture preserves complete raw source inputs while remaining partial" do
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: "older")
      .returns(account: account_row, response: { items: [ timeline_item ] }, next_cursor: "oldest")
    @client.expects(:get_event_detail).with(event_id: "event-1").returns(account: account_row, response: detail_response)
    capture = @adapter.capture_timeline_page(topic: "timelineTransactions", cursor: "older")
    refute capture.complete?
    assert_empty capture.records
    assert_equal "oldest", capture.evidence["response"]["next_cursor"]
    assert_equal "older", capture.evidence["request_cursor"]
    assert_equal detail_response.deep_stringify_keys, capture.evidence["details"]["event-1"]
  end

  test "detail budget exhaustion cannot be mistaken for a complete empty result" do
    rows = Array.new(201) { |index| timeline_item.merge(id: "event-#{index}") }
    @client.expects(:get_timeline_page).returns(account: account_row, response: { items: rows }, next_cursor: nil)
    @client.expects(:get_event_detail).never
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.capture_timeline_page(topic: "timelineTransactions") }
  end

  test "timeline captures from another account are rejected before normalization" do
    wrong = Ingestion::Record.account(**@portfolio.attributes.merge(external_id: "OTHER"))
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.normalize_timeline_page(capture: captured_page(items: [ timeline_item ], details: { "event-1" => detail_response }), account: wrong)
    end
  end

  private
    def adapter(**values)
      Provider::AccountData::TradeRepublic.new(**{ client: @client, timezone: "UTC", observed_at: Time.utc(2026, 9, 14, 12) }.merge(values))
    end

    def account_row
      { securitiesAccountNumber: "DE123", currency: "EUR" }
    end

    def raw_position
      { instrumentId: "US0378331005", netSize: "2.5", averageBuyIn: "90.25", name: "Apple" }
    end

    def stub_portfolio(positions: [ raw_position ])
      @client.expects(:get_portfolio).returns(account: account_row, portfolio: { categories: [ { categoryType: "stocksAndETFs", positions: positions } ] })
    end

    def position
      { isin: "US0378331005", name: "Apple", quantity: "2.5", price: "100.125", average_cost: "90.25" }
    end

    def trade_detail
      { isin: "US0378331005", name: "Apple", quantity: "2.5", amount: "251", currency: "EUR", fees: "1.00", taxes: "0.25" }
    end

    def event(**values)
      { id: "event-1", timestamp: "2026-09-12T12:30:00Z", category: "orderExecution" }.merge(values)
    end

    def timeline_item
      { id: "event-1", timestamp: "2026-09-12T12:30:00Z", eventType: "ORDER_EXECUTED", title: "Apple", instrumentId: "US0378331005", amount: { value: "-1234.56", currency: "EUR" } }
    end

    def detail_response
      { sections: [ { title: "Transaction", data: [
        { title: "Anteile", detail: { text: "2,5" } },
        { title: "Gesamt", detail: { value: { text: "1.234,56 EUR", currency: "EUR" } } },
        { title: "Gebühr", detail: { text: "1,25 EUR" } }
      ] } ] }
    end

    def captured_page(items:, details:)
      Provider::AccountData::Page.new(records: [], complete: false, mode: "delta", evidence: {
        topic: "timelineTransactions", request_cursor: nil, response: { account: account_row, response: { items: items }, next_cursor: nil }, details: details
      })
    end
end
