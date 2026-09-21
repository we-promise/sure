require "test_helper"

class SnaptradeAccount::ActivitiesProcessorTest < ActiveSupport::TestCase
  include SecuritiesTestHelper

  setup do
    @family = families(:dylan_family)
    @snaptrade_item = snaptrade_items(:configured_item)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)

    # Create a linked Sure account for the SnapTrade account
    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 50000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Investment.new
    )

    # Link the SnapTrade account to the Sure account
    @snaptrade_account.ensure_account_provider!(@account)
    @snaptrade_account.reload
  end

  test "processes buy trade activity" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_001",
        type: "BUY",
        symbol: "AAPL",
        units: 10,
        price: 150.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # Verify a trade was created (external_id is on entry, not trade)
    entry = @account.entries.find_by(external_id: "trade_001", source: "snaptrade")
    assert_not_nil entry, "Entry should be created"
    assert entry.entryable.is_a?(Trade), "Entry should be a Trade"

    trade = entry.entryable
    assert_equal 10, trade.qty
    assert_equal 150.00, trade.price.to_f
    assert_equal "Buy", trade.investment_activity_label
  end

  test "processes sell trade activity with negative quantity" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_002",
        type: "SELL",
        symbol: "AAPL",
        units: 5,
        price: 160.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "trade_002", source: "snaptrade")
    assert_not_nil entry
    trade = entry.entryable
    assert_equal(-5, trade.qty)  # Sell should be negative
    assert_equal "Sell", trade.investment_activity_label
  end

  test "the trade amount, qty, price, and fee reported by SnapTrade are respected" do
    process_activities(
      build_trade_activity(id: "buy_rounded", type: "BUY", symbol: "AAPL", units: 3, price: 33.33, amount: -101.00, fee: 1.00)
    )

    entry = snaptrade_entry("buy_rounded")
    assert_equal BigDecimal("101"), entry.amount
    assert_equal BigDecimal("3"), entry.entryable.qty
    assert_equal BigDecimal("33.33"), entry.entryable.price
    assert_equal BigDecimal("1.00"), entry.entryable.fee
  end

  test "fractional share quantity is stored exactly" do
    process_activities(
      build_trade_activity(id: "buy_fractional", type: "BUY", symbol: "VTI", units: 0.12345678, price: 149.94, amount: -18.51)
    )

    entry = snaptrade_entry("buy_fractional")
    assert_equal BigDecimal("0.12345678"), entry.entryable.qty
    assert_equal BigDecimal("18.51"), entry.amount
  end

  test "trade direction comes from the activity type, not the sign of SnapTrade's amount" do
    process_activities(
      build_trade_activity(id: "buy_positive_amount", type: "BUY", symbol: "AAPL", units: 3, price: 33.33, amount: 100.00),
      build_trade_activity(id: "sell_negative_amount", type: "SELL", symbol: "AAPL", units: 7, price: 14.29, amount: -100.00)
    )

    assert_equal BigDecimal("100"), snaptrade_entry("buy_positive_amount").amount
    assert_equal BigDecimal("-100"), snaptrade_entry("sell_negative_amount").amount
  end

  test "records the trade fee as a cost regardless of the sign SnapTrade gives it" do
    process_activities(
      build_trade_activity(id: "buy_negative_fee", type: "BUY", symbol: "AAPL", units: 10, price: 150.00, amount: -1504.95, fee: -4.95)
    )

    assert_equal BigDecimal("4.95"), snaptrade_entry("buy_negative_fee").entryable.fee
  end

  test "a zero reported amount falls back to qty times price" do
    process_activities(
      build_trade_activity(id: "buy_zero_amount", type: "BUY", symbol: "AAPL", units: 2, price: 50.00, amount: 0)
    )

    assert_equal BigDecimal("100"), snaptrade_entry("buy_zero_amount").amount
  end

  test "when amount is not reported, the fallback amount includes the fee like a manually entered trade" do
    process_activities(
      build_trade_activity(id: "buy_no_amount", type: "BUY", symbol: "AAPL", units: 10, price: 150.00, fee: 4.95),
      build_trade_activity(id: "sell_no_amount", type: "SELL", symbol: "AAPL", units: 10, price: 150.00, fee: 4.95)
    )

    assert_equal BigDecimal("1504.95"), snaptrade_entry("buy_no_amount").amount
    assert_equal BigDecimal("-1495.05"), snaptrade_entry("sell_no_amount").amount
  end

  test "imports the trade with a price derived from amount and units, and creates debug log, when price is missing" do
    process_activities(
      build_trade_activity(id: "buy_no_price", type: "BUY", symbol: "AAPL", units: 4, price: nil, amount: -100.00)
    )

    entry = snaptrade_entry("buy_no_price")
    assert_not_nil entry, "a trade with units and amount but no price must still be imported"
    assert_equal BigDecimal("25"), entry.entryable.price
    assert_equal BigDecimal("4"), entry.entryable.qty
    assert_equal BigDecimal("100"), entry.amount

    log = snaptrade_debug_log("buy_no_price", level: "info")
    assert_equal "derived_price", log&.metadata&.dig("reason")
    assert_equal "25.0", log&.metadata&.dig("derived_price")
  end

  test "imports a fully reported trade without creating debug log" do
    process_activities(
      build_trade_activity(id: "buy_complete", type: "BUY", symbol: "AAPL", units: 3, price: 33.33, amount: -101.00, fee: 1.00)
    )

    assert_not_nil snaptrade_entry("buy_complete")
    assert DebugLogEntry.where(provider_key: "snaptrade").none? { |log| log.metadata["activity_id"] == "buy_complete" },
           "routine trades must not flood /settings/debug"
  end

  test "a price derived from amount and units excludes the fee for buys and sells" do
    process_activities(
      build_trade_activity(id: "buy_no_price_fee", type: "BUY", symbol: "AAPL", units: 10, price: nil, amount: -1505.00, fee: 5.00),
      build_trade_activity(id: "sell_no_price_fee", type: "SELL", symbol: "AAPL", units: 10, price: nil, amount: 1495.00, fee: 5.00)
    )

    assert_equal BigDecimal("150"), snaptrade_entry("buy_no_price_fee").entryable.price
    assert_equal BigDecimal("150"), snaptrade_entry("sell_no_price_fee").entryable.price
  end

  test "resyncing keeps the stored fee when SnapTrade omits it, but applies a reported zero" do
    process_activities(
      build_trade_activity(id: "buy_fee_omitted", type: "BUY", symbol: "AAPL", units: 10, price: 150.00, amount: -1504.95, fee: 4.95)
    )

    process_activities(
      build_trade_activity(id: "buy_fee_omitted", type: "BUY", symbol: "AAPL", units: 10, price: 150.00, amount: -1504.95)
    )
    assert_equal BigDecimal("4.95"), snaptrade_entry("buy_fee_omitted").entryable.reload.fee

    process_activities(
      build_trade_activity(id: "buy_fee_omitted", type: "BUY", symbol: "AAPL", units: 10, price: 150.00, amount: -1500.00, fee: 0)
    )
    assert_equal BigDecimal("0"), snaptrade_entry("buy_fee_omitted").entryable.reload.fee
  end

  test "resyncing corrects the amount of a previously imported trade" do
    process_activities(
      build_trade_activity(id: "buy_resync", type: "BUY", symbol: "AAPL", units: 3, price: 33.33)
    )
    assert_equal BigDecimal("99.99"), snaptrade_entry("buy_resync").amount

    assert_no_difference -> { @account.entries.count } do
      process_activities(
        build_trade_activity(id: "buy_resync", type: "BUY", symbol: "AAPL", units: 3, price: 33.33, amount: -100.00)
      )
    end

    assert_equal BigDecimal("100"), snaptrade_entry("buy_resync").amount
  end

  test "processes dividend cash activity as negative inflow" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "div_001",
        type: "DIVIDEND",
        amount: 25.50,
        settlement_date: Date.current.to_s,
        symbol: "VTI"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "div_001", source: "snaptrade")
    assert_not_nil entry, "Entry should be created"
    assert entry.entryable.is_a?(Transaction), "Entry should be a Transaction"

    transaction = entry.entryable
    assert_equal(-25.50, entry.amount.to_f)
    assert_equal "Dividend", transaction.investment_activity_label
  end

  test "processes contribution with negative inflow amount" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "contrib_001",
        type: "CONTRIBUTION",
        amount: 500.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "contrib_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal(-500.00, entry.amount.to_f)
    assert_equal "Contribution", entry.entryable.investment_activity_label
  end

  test "processes withdrawal with positive outflow amount" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "withdraw_001",
        type: "WITHDRAWAL",
        amount: 200.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "withdraw_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal 200.00, entry.amount.to_f
    assert_equal "Withdrawal", entry.entryable.investment_activity_label
  end

  test "processes transfers with Sure sign convention" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "transfer_in_001",
        type: "TRANSFER_IN",
        amount: 300.00,
        settlement_date: Date.current.to_s
      ),
      build_cash_activity(
        id: "transfer_out_001",
        type: "TRANSFER_OUT",
        amount: 125.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    transfer_in = @account.entries.find_by(external_id: "transfer_in_001", source: "snaptrade")
    transfer_out = @account.entries.find_by(external_id: "transfer_out_001", source: "snaptrade")

    assert_not_nil transfer_in
    assert_not_nil transfer_out
    assert_equal(-300.00, transfer_in.amount.to_f)
    assert_equal 125.00, transfer_out.amount.to_f
    assert_equal "Transfer", transfer_in.entryable.investment_activity_label
    assert_equal "Transfer", transfer_out.entryable.investment_activity_label
  end

  test "normalizes bare TRANSFER from the provider sign" do
    # Regression test for issue #2756. Unlike TRANSFER_IN/TRANSFER_OUT, a bare "TRANSFER"
    # carries no direction in the type, so SnapTrade's sign is the only directional signal
    # available and must be inverted into Sure's convention rather than passed through.
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "transfer_generic_in",
        type: "TRANSFER",
        amount: 1320.75,
        settlement_date: Date.current.to_s
      ),
      build_cash_activity(
        id: "transfer_generic_out",
        type: "TRANSFER",
        amount: -500.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    inbound = @account.entries.find_by(external_id: "transfer_generic_in", source: "snaptrade")
    outbound = @account.entries.find_by(external_id: "transfer_generic_out", source: "snaptrade")

    assert_not_nil inbound
    assert_not_nil outbound
    assert_equal(-1320.75, inbound.amount.to_f, "money in must be stored negative on an asset account")
    assert_equal 500.00, outbound.amount.to_f, "money out must be stored positive on an asset account"
  end

  test "processes REBATE as negative cash inflow" do
    process_activities(
      build_cash_activity(id: "rebate_001", type: "REBATE", amount: 50.00, settlement_date: Date.current.to_s)
    )

    entry = snaptrade_entry("rebate_001")
    assert_not_nil entry
    assert_equal(-50.00, entry.amount.to_f, "rebate credited to account must be stored as negative inflow")
    assert_equal "Other", entry.entryable.investment_activity_label
  end

  test "processes RETURN_OF_CAPITAL, DISTRIBUTION, and SUBSTITUTE_DIVIDEND as negative cash inflows with Dividend label" do
    process_activities(
      build_cash_activity(id: "roc_001", type: "RETURN_OF_CAPITAL", amount: 75.00, settlement_date: Date.current.to_s, symbol: "VTI"),
      build_cash_activity(id: "dist_001", type: "DISTRIBUTION", amount: 120.00, settlement_date: Date.current.to_s, symbol: "VNQ"),
      build_cash_activity(id: "sub_div_001", type: "SUBSTITUTE_DIVIDEND", amount: 45.00, settlement_date: Date.current.to_s, symbol: "AAPL")
    )

    roc = snaptrade_entry("roc_001")
    dist = snaptrade_entry("dist_001")
    sub_div = snaptrade_entry("sub_div_001")

    assert_not_nil roc
    assert_not_nil dist
    assert_not_nil sub_div
    assert_equal(-75.00, roc.amount.to_f)
    assert_equal "Dividend", roc.entryable.investment_activity_label
    assert_equal(-120.00, dist.amount.to_f)
    assert_equal "Dividend", dist.entryable.investment_activity_label
    assert_equal(-45.00, sub_div.amount.to_f)
    assert_equal "Dividend", sub_div.entryable.investment_activity_label
  end

  test "processes cash FEE and TAX as positive outflow and INTEREST as negative inflow" do
    process_activities(
      build_cash_activity(id: "fee_001", type: "FEE", amount: -25.00, settlement_date: Date.current.to_s),
      build_cash_activity(id: "tax_001", type: "TAX", amount: 15.00, settlement_date: Date.current.to_s),
      build_cash_activity(id: "interest_001", type: "INTEREST", amount: 12.50, settlement_date: Date.current.to_s)
    )

    fee = snaptrade_entry("fee_001")
    tax = snaptrade_entry("tax_001")
    interest = snaptrade_entry("interest_001")

    assert_not_nil fee
    assert_not_nil tax
    assert_not_nil interest

    assert_equal 25.00, fee.amount.to_f
    assert_equal "Fee", fee.entryable.investment_activity_label

    assert_equal 15.00, tax.amount.to_f
    assert_equal "Fee", tax.entryable.investment_activity_label

    assert_equal(-12.50, interest.amount.to_f)
    assert_equal "Interest", interest.entryable.investment_activity_label
  end

  test "processes INTERNAL_CASH_TRANSFER_IN and OUT with correct signs" do
    process_activities(
      build_cash_activity(id: "int_cash_in", type: "INTERNAL_CASH_TRANSFER_IN", amount: 250.00, settlement_date: Date.current.to_s),
      build_cash_activity(id: "int_cash_out", type: "INTERNAL_CASH_TRANSFER_OUT", amount: 100.00, settlement_date: Date.current.to_s)
    )

    inbound = snaptrade_entry("int_cash_in")
    outbound = snaptrade_entry("int_cash_out")

    assert_not_nil inbound
    assert_not_nil outbound
    assert_equal(-250.00, inbound.amount.to_f)
    assert_equal "Transfer", inbound.entryable.investment_activity_label
    assert_equal 100.00, outbound.amount.to_f
    assert_equal "Transfer", outbound.entryable.investment_activity_label
  end

  test "processes cash ADJUSTMENT by inverting provider sign" do
    process_activities(
      build_cash_activity(id: "adj_credit", type: "ADJUSTMENT", amount: 15.00, settlement_date: Date.current.to_s),
      build_cash_activity(id: "adj_debit", type: "ADJUSTMENT", amount: -20.00, settlement_date: Date.current.to_s)
    )

    credit = snaptrade_entry("adj_credit")
    debit = snaptrade_entry("adj_debit")

    assert_not_nil credit
    assert_not_nil debit
    assert_equal(-15.00, credit.amount.to_f, "credit adjustment must be stored as negative inflow")
    assert_equal 20.00, debit.amount.to_f, "debit adjustment must be stored as positive outflow"
  end

  test "processes forward SPLIT as zero-cash trade adding shares (LAB-156)" do
    process_activities(
      build_trade_activity(
        id: "split_001",
        type: "SPLIT",
        symbol: "VGT",
        units: 3010.014,
        price: 0.0,
        amount: 304071.61 # SnapTrade notional value must NOT become a cash withdrawal
      )
    )

    entry = snaptrade_entry("split_001")
    assert_not_nil entry
    assert entry.entryable.is_a?(Trade), "SPLIT must be imported as a Trade, not a cash Transaction"
    trade = entry.entryable
    assert_equal BigDecimal("3010.014"), trade.qty
    assert_equal BigDecimal("0"), trade.price
    assert_equal BigDecimal("0"), entry.amount, "cash impact must be zero to prevent balance distortion"
    assert_equal "Other", trade.investment_activity_label
  end

  test "processes REVERSE_SPLIT as zero-cash trade with negative quantity" do
    process_activities(
      build_trade_activity(
        id: "rev_split_001",
        type: "REVERSE_SPLIT",
        symbol: "SOXL",
        units: 50.0,
        price: 0.0
      )
    )

    entry = snaptrade_entry("rev_split_001")
    assert_not_nil entry
    assert entry.entryable.is_a?(Trade)
    trade = entry.entryable
    assert_equal BigDecimal("-50.0"), trade.qty
    assert_equal BigDecimal("0"), trade.price
    assert_equal BigDecimal("0"), entry.amount
    assert_equal "Other", trade.investment_activity_label
  end

  test "processes STOCK_DIVIDEND as zero-cash trade with Dividend label" do
    process_activities(
      build_trade_activity(
        id: "stock_div_001",
        type: "STOCK_DIVIDEND",
        symbol: "AAPL",
        units: 2.0,
        price: 0.0
      )
    )

    entry = snaptrade_entry("stock_div_001")
    assert_not_nil entry
    assert entry.entryable.is_a?(Trade)
    trade = entry.entryable
    assert_equal BigDecimal("2.0"), trade.qty
    assert_equal BigDecimal("0"), trade.price
    assert_equal BigDecimal("0"), entry.amount
    assert_equal "Dividend", trade.investment_activity_label
  end

  test "processes SPINOFF as zero-cash trade" do
    process_activities(
      build_trade_activity(
        id: "spinoff_001",
        type: "SPINOFF",
        symbol: "GEV",
        units: 10.0,
        price: 0.0
      )
    )

    entry = snaptrade_entry("spinoff_001")
    assert_not_nil entry
    assert entry.entryable.is_a?(Trade)
    trade = entry.entryable
    assert_equal BigDecimal("10.0"), trade.qty
    assert_equal BigDecimal("0"), trade.price
    assert_equal BigDecimal("0"), entry.amount
    assert_equal "Other", trade.investment_activity_label
  end

  test "processes OPTIONASSIGNMENT and OPTIONEXERCISE as trades" do
    process_activities(
      build_trade_activity(
        id: "opt_assign_001",
        type: "OPTIONASSIGNMENT",
        symbol: "AAPL",
        units: 1.0,
        price: 150.0
      ),
      build_trade_activity(
        id: "opt_exercise_001",
        type: "OPTIONEXERCISE",
        symbol: "MSFT",
        units: 1.0,
        price: 300.0
      )
    )

    assign = snaptrade_entry("opt_assign_001")
    exercise = snaptrade_entry("opt_exercise_001")

    assert_not_nil assign
    assert_not_nil exercise
    assert assign.entryable.is_a?(Trade)
    assert exercise.entryable.is_a?(Trade)
    assert_equal BigDecimal("-1.0"), assign.entryable.qty, "assignment should be sell-side (negative)"
    assert_equal BigDecimal("1.0"), exercise.entryable.qty
  end

  test "processes EXTERNAL_ASSET_TRANSFER_IN and OUT as zero-cash asset trades" do
    process_activities(
      build_trade_activity(
        id: "acat_in_001",
        type: "EXTERNAL_ASSET_TRANSFER_IN",
        symbol: "VTI",
        units: 100.0,
        price: 220.0
      ),
      build_trade_activity(
        id: "acat_out_001",
        type: "EXTERNAL_ASSET_TRANSFER_OUT",
        symbol: "VXUS",
        units: 50.0,
        price: 60.0
      )
    )

    inbound = snaptrade_entry("acat_in_001")
    outbound = snaptrade_entry("acat_out_001")

    assert_not_nil inbound
    assert_not_nil outbound
    assert inbound.entryable.is_a?(Trade)
    assert outbound.entryable.is_a?(Trade)
    assert_equal BigDecimal("100.0"), inbound.entryable.qty
    assert_equal BigDecimal("-50.0"), outbound.entryable.qty
    assert_equal BigDecimal("0"), inbound.amount, "ACAT transfer in has zero cash flow"
    assert_equal BigDecimal("0"), outbound.amount, "ACAT transfer out has zero cash flow"
    assert_equal "Transfer", inbound.entryable.investment_activity_label
    assert_equal "Transfer", outbound.entryable.investment_activity_label
  end

  test "processes INTERNAL_ASSET_TRANSFER_IN and OUT as zero-cash asset trades" do
    process_activities(
      build_trade_activity(
        id: "int_asset_in_001",
        type: "INTERNAL_ASSET_TRANSFER_IN",
        symbol: "VTI",
        units: 25.0,
        price: 220.0
      ),
      build_trade_activity(
        id: "int_asset_out_001",
        type: "INTERNAL_ASSET_TRANSFER_OUT",
        symbol: "VXUS",
        units: 15.0,
        price: 60.0
      )
    )

    inbound = snaptrade_entry("int_asset_in_001")
    outbound = snaptrade_entry("int_asset_out_001")

    assert_not_nil inbound
    assert_not_nil outbound
    assert inbound.entryable.is_a?(Trade)
    assert outbound.entryable.is_a?(Trade)
    assert_equal BigDecimal("25.0"), inbound.entryable.qty
    assert_equal BigDecimal("-15.0"), outbound.entryable.qty
    assert_equal BigDecimal("0"), inbound.amount, "internal asset transfer in has zero cash flow"
    assert_equal BigDecimal("0"), outbound.amount, "internal asset transfer out has zero cash flow"
    assert_equal "Transfer", inbound.entryable.investment_activity_label
    assert_equal "Transfer", outbound.entryable.investment_activity_label
  end

  test "processes zero-amount trade types when price and amount are omitted" do
    process_activities(
      build_trade_activity(
        id: "opt_exp_001",
        type: "OPTIONEXPIRATION",
        symbol: "AAPL",
        units: 1.0,
        price: nil,
        amount: nil
      )
    )

    entry = snaptrade_entry("opt_exp_001")
    assert_not_nil entry, "zero-amount trade types must import even when price and amount are omitted"
    assert entry.entryable.is_a?(Trade)
    assert_equal BigDecimal("1.0"), entry.entryable.qty
    assert_equal BigDecimal("0"), entry.entryable.price
    assert_equal BigDecimal("0"), entry.amount
    assert_equal "Other", entry.entryable.investment_activity_label
  end

  test "processes share ADJUSTMENT as a zero-cash trade when units are present" do
    process_activities(
      build_trade_activity(
        id: "share_adj_001",
        type: "ADJUSTMENT",
        symbol: "VTI",
        units: 5.0,
        price: nil,
        amount: 500.00 # Notional value must not become cash flow
      )
    )

    entry = snaptrade_entry("share_adj_001")
    assert_not_nil entry
    assert entry.entryable.is_a?(Trade), "ADJUSTMENT with units must be imported as a Trade"
    assert_equal BigDecimal("5.0"), entry.entryable.qty
    assert_equal BigDecimal("0"), entry.entryable.price
    assert_equal BigDecimal("0"), entry.amount
    assert_equal "Other", entry.entryable.investment_activity_label
  end

  test "ignores cash activities with zero or nil amount" do
    assert_no_difference -> { @account.entries.count } do
      process_activities(
        build_cash_activity(id: "zero_cash_001", type: "DIVIDEND", amount: 0.0, settlement_date: Date.current.to_s),
        build_cash_activity(id: "nil_cash_001", type: "CONTRIBUTION", amount: nil, settlement_date: Date.current.to_s)
      )
    end
  end

  test "imports an unmapped activity type as Other and creates debug log" do
    process_activities(
      build_cash_activity(id: "unknown_001", type: "SOME_NEW_TYPE", amount: 100.00, settlement_date: Date.current.to_s)
    )

    entry = snaptrade_entry("unknown_001")
    assert_not_nil entry, "an unmapped activity type is still imported"
    assert_equal "Other", entry.entryable.investment_activity_label

    log = DebugLogEntry.where(provider_key: "snaptrade", category: "provider_sync", level: "warn")
                       .find { |e| e.metadata["activity_type"] == "SOME_NEW_TYPE" }
    assert_not_nil log, "an unmapped activity type must be recorded in /settings/debug"
    assert_equal @family, log.family
    assert_equal @snaptrade_account.account_provider, log.account_provider
  end

  test "skips the trade and creates debug log when symbol is missing" do
    assert_no_difference -> { @account.entries.count } do
      process_activities(
        build_trade_activity(id: "skip_no_symbol", type: "BUY", symbol: nil, units: 1, price: 10.00, amount: -10.00)
      )
    end

    assert_equal "missing_symbol", snaptrade_debug_log("skip_no_symbol")&.metadata&.dig("reason")
  end

  test "skips the trade and creates debug log when quantity is missing" do
    assert_no_difference -> { @account.entries.count } do
      process_activities(
        build_trade_activity(id: "skip_no_quantity", type: "BUY", symbol: "AAPL", units: nil, price: 10.00, amount: -10.00)
      )
    end

    assert_equal "missing_quantity", snaptrade_debug_log("skip_no_quantity")&.metadata&.dig("reason")
  end

  test "skips the trade and creates debug log when amount and price are both missing" do
    assert_no_difference -> { @account.entries.count } do
      process_activities(
        build_trade_activity(id: "skip_no_amount", type: "BUY", symbol: "AAPL", units: 5, price: nil)
      )
    end

    log = snaptrade_debug_log("skip_no_amount")
    assert_equal "missing_amount", log&.metadata&.dig("reason")
    assert_equal @family, log.family
    assert_equal @snaptrade_account.account_provider, log.account_provider
  end

  test "skips the trade and creates debug log when security is unresolvable" do
    SnaptradeAccount::ActivitiesProcessor.any_instance.stubs(:resolve_security).returns(nil)

    assert_no_difference -> { @account.entries.count } do
      process_activities(
        build_trade_activity(id: "skip_unresolved", type: "BUY", symbol: "ZZZZ", units: 1, price: 10.00, amount: -10.00)
      )
    end

    log = snaptrade_debug_log("skip_unresolved")
    assert_equal "unresolved_security", log&.metadata&.dig("reason")
    assert_equal "ZZZZ", log&.metadata&.dig("ticker")
  end

  test "skips an activity that fails to import, keeps processing, and creates debug log" do
    Account::ProviderImportAdapter.any_instance.stubs(:import_trade).raises(StandardError, "boom")

    process_activities(
      build_trade_activity(id: "trade_fails", type: "BUY", symbol: "AAPL", units: 1, price: 10.00, amount: -10.00),
      build_cash_activity(id: "div_after_failure", type: "DIVIDEND", amount: 5.00, settlement_date: Date.current.to_s)
    )

    assert_nil snaptrade_entry("trade_fails")
    assert_not_nil snaptrade_entry("div_after_failure"), "later activities are still processed"

    log = snaptrade_debug_log("trade_fails", category: "provider_sync_error", level: "error")
    assert_not_nil log, "a failed activity must be recorded in /settings/debug"
    assert_equal "BUY", log.metadata["activity_type"]
    assert_includes log.message, "boom"
  end

  test "skips activities without external_id" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: nil,
        type: "DIVIDEND",
        amount: 50.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # No entry should be created with snaptrade source
    assert_equal 0, @account.entries.where(source: "snaptrade").count
  end

  test "skips processing when no linked account" do
    # Remove the account provider link
    @snaptrade_account.account_provider&.destroy
    @snaptrade_account.reload

    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_orphan",
        type: "BUY",
        symbol: "AAPL",
        units: 10,
        price: 150.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # No entries should be created with this external_id
    assert_equal 0, Entry.where(external_id: "trade_orphan").count
  end

  private

    def process_activities(*activities)
      @snaptrade_account.update!(raw_activities_payload: activities)
      SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account).process
    end

    def snaptrade_entry(external_id)
      @account.entries.find_by(external_id: external_id, source: "snaptrade")
    end

    def snaptrade_debug_log(activity_id, category: "provider_sync", level: "warn")
      DebugLogEntry.where(provider_key: "snaptrade", category: category, level: level)
                   .find { |log| log.metadata["activity_id"] == activity_id }
    end

    def build_trade_activity(id:, type:, symbol:, units:, price:, settlement_date: Date.current.to_s, amount: nil, fee: nil)
      activity = {
        "id" => id,
        "type" => type,
        "symbol" => {
          "symbol" => symbol,
          "description" => "#{symbol} Inc"
        },
        "units" => units,
        "price" => price,
        "settlement_date" => settlement_date,
        "currency" => { "code" => "USD" }
      }
      activity["amount"] = amount unless amount.nil?
      activity["fee"] = fee unless fee.nil?
      activity
    end

    def build_cash_activity(id:, type:, amount:, settlement_date:, symbol: nil)
      activity = {
        "id" => id,
        "type" => type,
        "amount" => amount,
        "settlement_date" => settlement_date,
        "currency" => { "code" => "USD" }
      }

      if symbol
        activity["symbol"] = {
          "symbol" => symbol,
          "description" => "#{symbol} Fund"
        }
      end

      activity
    end
end
