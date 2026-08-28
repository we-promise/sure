require "test_helper"

class TradeRepublicAccountActivitiesProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = trade_republic_items(:configured_item)
    @item.trade_republic_accounts.destroy_all

    @tr_account = @item.trade_republic_accounts.create!(
      name: "Processor Test",
      trade_republic_account_id: "DEPROC1",
      currency: "EUR"
    )
    @account = @family.accounts.create!(
      name: "Trade Republic Processor Test",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Investment.new
    )
    @tr_account.ensure_account_provider!(@account)
    @tr_account.reload
  end

  test "buy is imported as a trade with negative amount, never as spending income" do
    import_event(order_execution_detail(quantity: "13.439945", isin: "US0378331005", amount: "2472.14"))

    trade = find_trade("trade_republic_event_evt_buy")
    assert_not_nil trade
    assert_equal BigDecimal("13.439945"), trade.entryable.qty
    assert_equal "Buy", trade.entryable.investment_activity_label
    assert_equal BigDecimal("-2472.14"), trade.amount
  end

  test "fractional quantity retains exact precision" do
    import_event(order_execution_detail(quantity: "13.439945", isin: "US0378331005", amount: "2472.14"))

    trade = find_trade("trade_republic_event_evt_buy")
    assert_equal BigDecimal("13.439945"), trade.entryable.qty
    assert_equal BigDecimal("13.439945").to_s, trade.entryable.qty.to_s
  end

  test "sell imports negative quantity and positive amount" do
    import_event(order_execution_detail(
      event_id: "evt_sell",
      quantity: "-2.500000",
      isin: "US0378331005",
      amount: "459.85"
    ))

    trade = find_trade("trade_republic_event_evt_sell")
    assert_not_nil trade
    assert_equal BigDecimal("-2.5"), trade.entryable.qty
    assert_equal "Sell", trade.entryable.investment_activity_label
    assert_equal BigDecimal("459.85"), trade.amount
  end

  test "trade derives a missing amount from quantity and price" do
    import_event(order_execution_detail(
      event_id: "evt_price_only",
      quantity: "2.5",
      isin: "US0378331005",
      amount: nil
    ).deep_merge(detail: { price: "184.00" }))

    trade = find_trade("trade_republic_event_evt_price_only")
    assert_not_nil trade
    assert_equal BigDecimal("184.00"), trade.entryable.price
    assert_equal BigDecimal("-460.00"), trade.amount
  end

  test "syncing the same events twice creates no duplicates" do
    events = [
      order_execution_detail(quantity: "1.5", isin: "US0378331005", amount: "100.00"),
      deposit_event
    ]

    @tr_account.update!(raw_timeline_payload: events)
    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account).process

    assert_difference "Entry.where(source: 'trade_republic').count", 0 do
      TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    end
  end

  test "deposit maps to Contribution with negative amount" do
    import_event(deposit_event)

    entry = Entry.find_by(external_id: "trade_republic_event_evt_dep")
    assert_not_nil entry
    assert_equal BigDecimal("-500.00"), entry.amount
    assert_equal "Contribution", entry.transaction.investment_activity_label
  end

  test "withdrawal maps to Withdrawal with positive amount" do
    import_event({
      id: "evt_wd",
      timestamp: "2026-08-01T10:00:00Z",
      category: "POC_CREATED",
      detail: { amount: "300.00", currency: "EUR" }
    })

    entry = Entry.find_by(external_id: "trade_republic_event_evt_wd")
    assert_not_nil entry
    assert_equal BigDecimal("300.00"), entry.amount
    assert_equal "Withdrawal", entry.transaction.investment_activity_label
  end

  test "dividend maps to Dividend with negative amount" do
    import_event({
      id: "evt_dividend",
      timestamp: "2026-08-01T10:00:00Z",
      category: "DIVIDEND",
      detail: { amount: "25.50", currency: "EUR" }
    })

    entry = Entry.find_by(external_id: "trade_republic_event_evt_dividend")
    assert_not_nil entry
    assert_equal BigDecimal("-25.50"), entry.amount
    assert_equal "Dividend", entry.transaction.investment_activity_label
  end

  test "card events keep a card-specific activity label" do
    import_event({
      id: "evt_card_payment",
      timestamp: "2026-08-01T10:00:00Z",
      eventType: "CARD_TRANSACTION",
      category: "POC_CREATED",
      detail: { amount: "42.00", currency: "EUR" }
    })

    entry = Entry.find_by(external_id: "trade_republic_event_evt_card_payment")
    assert_equal "Card payment", entry.transaction.investment_activity_label
  end

  test "card cash back events that are purchases are imported as expenses with merchant details" do
    import_event({
      id: "evt_card_cash_back",
      timestamp: "2026-08-01T10:00:00Z",
      eventType: "CARD_CASH_BACK",
      category: "PAYMENT_RECEIVED",
      title: "Marktkauf",
      subtitle: "Card purchase",
      detail: { amount: "204.18", signed_amount: "-204.18", currency: "EUR" }
    })

    entry = Entry.find_by(external_id: "trade_republic_event_evt_card_cash_back")
    assert_equal BigDecimal("204.18"), entry.amount
    assert_equal "Marktkauf", entry.name
    assert_equal "Card payment", entry.transaction.investment_activity_label
    assert_equal "CARD_CASH_BACK", entry.transaction.extra.dig("trade_republic", "event_type")
    assert_equal "Card purchase", entry.transaction.extra.dig("trade_republic", "subtitle")
  end

  test "category direction wins over the provider signed amount" do
    import_event({
      id: "evt_incoming_signed",
      timestamp: "2026-08-01T10:00:00Z",
      category: "PAYMENT_RECEIVED",
      detail: { amount: "500.00", signed_amount: "500.00", currency: "EUR" }
    })

    assert_equal BigDecimal("-500.00"), Entry.find_by(external_id: "trade_republic_event_evt_incoming_signed").amount
  end

  test "unknown category is skipped without guessing a transaction" do
    assert_no_difference "Entry.count" do
      import_event({
        id: "evt_card",
        timestamp: "2026-08-01T10:00:00Z",
        category: "card_payment",
        detail: { amount: "42.00", currency: "EUR" }
      })
    end
  end

  test "unknown event does not prevent valid events from importing" do
    @tr_account.update!(raw_timeline_payload: [
      { id: "evt_unknown", timestamp: "2026-08-01T10:00:00Z", category: "future_event", detail: { amount: "42.00", currency: "EUR" } },
      deposit_event
    ])

    assert_difference "Entry.where(source: 'trade_republic').count", 1 do
      TradeRepublicAccount::ActivitiesProcessor.new(@tr_account).process
    end

    assert Entry.exists?(external_id: "trade_republic_event_evt_dep")
    assert_not Entry.exists?(external_id: "trade_republic_event_evt_unknown")
  end

  test "trade fee is retained as metadata and not imported as a second cash entry" do
    import_event(order_execution_detail(quantity: "1.5", isin: "US0378331005", amount: "100.00").deep_merge(detail: { fees: "1.00" }))

    assert_equal 1, Entry.where(source: "trade_republic").count
    trade = find_trade("trade_republic_event_evt_buy")
    assert_equal "1.00", trade.entryable.extra.dig("trade_republic", "fees")
  end

  test "event without normalized detail is skipped" do
    assert_no_difference "Entry.count" do
      import_event({
        id: "evt_nodetail",
        timestamp: "2026-08-01T10:00:00Z",
        category: "orderExecution"
      })
    end
  end

  test "split portfolio processing preserves legacy cash transactions when cash snapshot is empty" do
    @item.trade_republic_accounts.create!(
      name: "Cash",
      kind: "cash",
      trade_republic_account_id: "cash:DEPROC1",
      currency: "EUR",
      raw_timeline_payload: []
    )
    Account::ProviderImportAdapter.new(@account).import_transaction(
      external_id: "trade_republic_event_legacy_cash",
      amount: BigDecimal("-25.00"),
      currency: "EUR",
      date: Date.current,
      name: "Legacy card payment",
      source: "trade_republic"
    )

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process

    assert Entry.exists?(external_id: "trade_republic_event_legacy_cash")
  end

  test "split portfolio processing preserves cash events when the cash account is unlinked" do
    @item.trade_republic_accounts.create!(
      name: "Cash",
      kind: "cash",
      trade_republic_account_id: "cash:DEPROC1",
      currency: "EUR",
      raw_timeline_payload: [ { "id" => "cash_evt" } ]
    )
    adapter = Account::ProviderImportAdapter.new(@account)
    adapter.import_transaction(
      external_id: "trade_republic_event_cash_evt",
      amount: BigDecimal("-25.00"),
      currency: "EUR",
      date: Date.current,
      name: "Cash payment",
      source: "trade_republic"
    )
    adapter.import_transaction(
      external_id: "trade_republic_event_unknown_evt",
      amount: BigDecimal("-10.00"),
      currency: "EUR",
      date: Date.current,
      name: "Unseen payment",
      source: "trade_republic"
    )

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process

    assert Entry.exists?(external_id: "trade_republic_event_cash_evt")
    assert Entry.exists?(external_id: "trade_republic_event_unknown_evt")
  end

  private

    def import_event(event)
      @tr_account.update!(raw_timeline_payload: [ event ])
      TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    end

    def order_execution_detail(event_id: "evt_buy", quantity:, isin:, amount:)
      {
        id: event_id,
        timestamp: "2026-07-15T09:30:00Z",
        category: "orderExecution",
        detail: {
          isin: isin,
          name: "Apple Inc.",
          quantity: quantity,
          amount: amount,
          currency: "EUR"
        }
      }
    end

    def deposit_event
      {
        id: "evt_dep",
        timestamp: "2026-08-01T10:00:00Z",
        category: "PAYMENT_RECEIVED",
        detail: { amount: "500.00", currency: "EUR" }
      }
    end

    def find_trade(external_id)
      Entry.find_by(external_id: external_id)
    end
end
