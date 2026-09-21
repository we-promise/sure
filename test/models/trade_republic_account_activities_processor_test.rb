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

  test "order executions carry canonical activity labels under a non-English locale" do
    I18n.with_locale(:de) do
      import_event({
        id: "evt_buy_de",
        timestamp: "2026-08-01T10:00:00Z",
        category: "orderExecution",
        detail: { isin: "US0378331005", name: "Apple", quantity: "2", amount: "300.00", currency: "EUR" }
      })
    end

    entry = Entry.find_by(external_id: "trade_republic_event_evt_buy_de")
    assert_not_nil entry, "Trade::ACTIVITY_LABELS are canonical English, so order executions must import under any locale"
    assert_equal "Buy", entry.trade.investment_activity_label
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

  test "saveback imports as a portfolio trade and never as a cash transaction when split" do
    cash_account, cash_sure = create_linked_cash_account!

    saveback = saveback_event
    @tr_account.update!(raw_timeline_payload: [ saveback ])
    cash_account.update!(raw_timeline_payload: [ saveback ])

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    trade = find_trade("trade_republic_event_evt_saveback")
    assert_not_nil trade
    assert_equal "Trade", trade.entryable_type
    assert_equal BigDecimal("0.09329"), trade.entryable.qty
    assert_equal "Buy", trade.entryable.investment_activity_label
    assert_equal BigDecimal("-3.74"), trade.amount
    assert_equal "SAVEBACK_AGGREGATE", trade.entryable.extra.dig("trade_republic", "event_type")

    assert_not Entry.exists?(account: cash_sure, external_id: "trade_republic_event_evt_saveback")
  end

  test "round up imports as a portfolio trade and a cash outflow when split" do
    cash_account, cash_sure = create_linked_cash_account!

    round_up = round_up_event
    @tr_account.update!(raw_timeline_payload: [ round_up ])
    cash_account.update!(raw_timeline_payload: [ round_up ])

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    trade = find_trade("trade_republic_event_evt_round_up")
    assert_not_nil trade
    assert_equal "Trade", trade.entryable_type
    assert_equal BigDecimal("0.009977"), trade.entryable.qty
    assert_equal BigDecimal("-0.40"), trade.amount
    assert_equal "SPARE_CHANGE_AGGREGATE", trade.entryable.extra.dig("trade_republic", "event_type")

    cash_entry = Entry.find_by(account: cash_sure, external_id: "trade_republic_event_evt_round_up")
    assert_not_nil cash_entry
    assert_equal "Transaction", cash_entry.entryable_type
    assert_equal BigDecimal("0.40"), cash_entry.amount
    assert_equal "Round up", cash_entry.transaction.investment_activity_label
    assert_equal "SPARE_CHANGE_AGGREGATE", cash_entry.transaction.extra.dig("trade_republic", "event_type")
  end

  test "round up and saveback remain idempotent across repeated processing" do
    cash_account, cash_sure = create_linked_cash_account!
    events = [ saveback_event, round_up_event ]

    @tr_account.update!(raw_timeline_payload: events)
    cash_account.update!(raw_timeline_payload: events)

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    assert_difference -> { @account.entries.where(source: "trade_republic").count }, 0 do
      assert_difference -> { cash_sure.entries.where(source: "trade_republic").count }, 0 do
        TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
        TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process
      end
    end

    assert_equal 2, @account.entries.where(entryable_type: "Trade", source: "trade_republic").count
    assert_equal 1, cash_sure.entries.where(entryable_type: "Transaction", source: "trade_republic").count
  end

  test "incomplete saveback details are skipped on portfolio and never become cash" do
    cash_account, cash_sure = create_linked_cash_account!
    incomplete = saveback_event.deep_merge(detail: { isin: nil, quantity: nil })

    @tr_account.update!(raw_timeline_payload: [ incomplete ])
    cash_account.update!(raw_timeline_payload: [ incomplete ])

    assert_no_difference "Entry.where(source: 'trade_republic').count" do
      TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
      TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process
    end

    assert_not Entry.exists?(account: @account, external_id: "trade_republic_event_evt_saveback")
    assert_not Entry.exists?(account: cash_sure, external_id: "trade_republic_event_evt_saveback")
  end

  test "incomplete round up details still import cash but skip the portfolio trade" do
    cash_account, cash_sure = create_linked_cash_account!
    incomplete = round_up_event.deep_merge(detail: { isin: nil, quantity: nil })

    @tr_account.update!(raw_timeline_payload: [ incomplete ])
    cash_account.update!(raw_timeline_payload: [ incomplete ])

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    assert_not Entry.exists?(account: @account, external_id: "trade_republic_event_evt_round_up")

    cash_entry = Entry.find_by(account: cash_sure, external_id: "trade_republic_event_evt_round_up")
    assert_not_nil cash_entry
    assert_equal BigDecimal("0.40"), cash_entry.amount
    assert_equal "Round up", cash_entry.transaction.investment_activity_label
  end

  test "portfolio-only saveback and round up import as trades without cash entries" do
    @tr_account.update!(raw_timeline_payload: [ saveback_event, round_up_event ])

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process

    assert_equal 2, @account.entries.where(entryable_type: "Trade", source: "trade_republic").count
    assert_equal 0, @account.entries.where(entryable_type: "Transaction", source: "trade_republic").count
  end

  test "cash-only round up imports as cash while saveback is skipped" do
    @tr_account.destroy
    cash_provider = @item.trade_republic_accounts.create!(
      name: "Cash only",
      kind: "cash",
      trade_republic_account_id: "cash:DEPROC1",
      currency: "EUR",
      raw_timeline_payload: [ saveback_event, round_up_event ]
    )
    cash_sure = @family.accounts.create!(
      name: "Trade Republic Cash Only",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Depository.new
    )
    cash_provider.ensure_account_provider!(cash_sure)

    TradeRepublicAccount::ActivitiesProcessor.new(cash_provider.reload).process

    assert_not Entry.exists?(account: cash_sure, external_id: "trade_republic_event_evt_saveback")
    cash_entry = Entry.find_by(account: cash_sure, external_id: "trade_republic_event_evt_round_up")
    assert_not_nil cash_entry
    assert_equal BigDecimal("0.40"), cash_entry.amount
  end

  test "reconciles unprotected legacy saveback cash transactions" do
    cash_account, cash_sure = create_linked_cash_account!
    saveback = saveback_event

    Account::ProviderImportAdapter.new(cash_sure).import_transaction(
      external_id: "trade_republic_event_evt_saveback",
      amount: BigDecimal("3.74"),
      currency: "EUR",
      date: Date.parse("2026-09-02"),
      name: "STOXX Global Dividend 100 EUR (Dist)",
      source: "trade_republic",
      investment_activity_label: "Withdrawal",
      extra: {
        trade_republic: {
          event_id: "trade_republic_event_evt_saveback",
          event_type: "SAVEBACK_AGGREGATE",
          title: "STOXX Global Dividend 100 EUR (Dist)",
          subtitle: "Saveback"
        }
      }
    )

    cash_account.update!(raw_timeline_payload: [ saveback ])
    @tr_account.update!(raw_timeline_payload: [ saveback ])

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    assert Entry.exists?(account: @account, external_id: "trade_republic_event_evt_saveback", entryable_type: "Trade")
    assert_not Entry.exists?(account: cash_sure, external_id: "trade_republic_event_evt_saveback")
  end

  test "preserves protected legacy saveback cash transactions during reconciliation" do
    cash_account, cash_sure = create_linked_cash_account!
    saveback = saveback_event

    entry = Account::ProviderImportAdapter.new(cash_sure).import_transaction(
      external_id: "trade_republic_event_evt_saveback",
      amount: BigDecimal("3.74"),
      currency: "EUR",
      date: Date.parse("2026-09-02"),
      name: "STOXX Global Dividend 100 EUR (Dist)",
      source: "trade_republic",
      investment_activity_label: "Withdrawal",
      extra: {
        trade_republic: {
          event_id: "trade_republic_event_evt_saveback",
          event_type: "SAVEBACK_AGGREGATE"
        }
      }
    )
    entry.mark_user_modified!

    cash_account.update!(raw_timeline_payload: [ saveback ])

    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    assert Entry.exists?(account: cash_sure, external_id: "trade_republic_event_evt_saveback")
    assert entry.reload.user_modified?
  end

  test "savings-plan invoice imports as a portfolio trade and never as cash" do
    cash_account, cash_sure = create_linked_cash_account!
    event = savings_plan_invoice_event

    @tr_account.update!(raw_timeline_payload: [ event ])
    cash_account.update!(raw_timeline_payload: [ event ])

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    trade = find_trade("trade_republic_event_evt_savings_plan")
    assert_not_nil trade
    assert_equal "Trade", trade.entryable_type
    assert_equal BigDecimal("0.25"), trade.entryable.qty
    assert_equal "Buy", trade.entryable.investment_activity_label
    assert_equal BigDecimal("-25.00"), trade.amount
    assert_equal "SAVINGS_PLAN_INVOICE_CREATED", trade.entryable.extra.dig("trade_republic", "event_type")

    assert_not Entry.exists?(account: cash_sure, external_id: "trade_republic_event_evt_savings_plan")
  end

  test "savings-plan invoice remains idempotent across repeated processing" do
    cash_account, cash_sure = create_linked_cash_account!
    event = savings_plan_invoice_event

    @tr_account.update!(raw_timeline_payload: [ event ])
    cash_account.update!(raw_timeline_payload: [ event ])

    TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
    TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process

    assert_difference -> { @account.entries.where(source: "trade_republic").count }, 0 do
      assert_difference -> { cash_sure.entries.where(source: "trade_republic").count }, 0 do
        TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
        TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process
      end
    end

    assert_equal 1, @account.entries.where(entryable_type: "Trade", source: "trade_republic").count
    assert_equal 0, cash_sure.entries.where(source: "trade_republic").count
  end

  test "failed savings-plan executions remain ignored" do
    cash_account, = create_linked_cash_account!
    failed = {
      id: "evt_savings_failed",
      timestamp: "2026-06-17T10:00:00Z",
      eventType: "TRADING_SAVINGSPLAN_EXECUTION_FAILED",
      title: "MSCI World",
      detail: { amount: -25.0, currency: "EUR" }
    }

    @tr_account.update!(raw_timeline_payload: [ failed ])
    cash_account.update!(raw_timeline_payload: [ failed ])

    assert_no_difference "Entry.where(source: 'trade_republic').count" do
      TradeRepublicAccount::ActivitiesProcessor.new(@tr_account.reload).process
      TradeRepublicAccount::ActivitiesProcessor.new(cash_account.reload).process
    end

    assert_not Entry.exists?(external_id: "trade_republic_event_evt_savings_failed")
  end

  private

    def create_linked_cash_account!
      cash_provider = @item.trade_republic_accounts.create!(
        name: "Cash",
        kind: "cash",
        trade_republic_account_id: "cash:DEPROC1",
        currency: "EUR",
        raw_timeline_payload: []
      )
      cash_sure = @family.accounts.create!(
        name: "Trade Republic Cash",
        balance: 0,
        cash_balance: 0,
        currency: "EUR",
        accountable: Depository.new
      )
      cash_provider.ensure_account_provider!(cash_sure)
      [ cash_provider.reload, cash_sure ]
    end

    def saveback_event
      {
        id: "evt_saveback",
        timestamp: "2026-09-02T08:11:30.780+0000",
        eventType: "SAVEBACK_AGGREGATE",
        category: "POC_CREATED",
        title: "STOXX Global Dividend 100 EUR (Dist)",
        subtitle: "Saveback",
        detail: {
          amount: "3.74",
          signed_amount: "-3.74",
          currency: "EUR",
          quantity: "0.09329",
          isin: "DE000A0F5UH1",
          name: "STOXX Global Dividend 100 EUR (Dist)"
        }
      }
    end

    def round_up_event
      {
        id: "evt_round_up",
        timestamp: "2026-09-02T08:11:30.780+0000",
        eventType: "SPARE_CHANGE_AGGREGATE",
        category: "POC_CREATED",
        title: "STOXX Global Dividend 100 EUR (Dist)",
        subtitle: "Round up",
        detail: {
          amount: "-0.40",
          signed_amount: "-0.40",
          currency: "EUR",
          quantity: "0.009977",
          isin: "DE000A0F5UH1",
          name: "STOXX Global Dividend 100 EUR (Dist)"
        }
      }
    end

    def savings_plan_invoice_event
      {
        id: "evt_savings_plan",
        timestamp: "2026-06-17T10:00:00Z",
        eventType: "SAVINGS_PLAN_INVOICE_CREATED",
        category: "orderExecution",
        title: "MSCI World",
        subtitle: "Savings plan",
        detail: {
          amount: "25.00",
          signed_amount: "-25.00",
          currency: "EUR",
          quantity: "0.25",
          isin: "IE00B4L5Y983",
          name: "MSCI World"
        }
      }
    end

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
