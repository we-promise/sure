require "test_helper"

class IbkrAccount::HistoricalBalancesSyncTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "IBKR Brokerage",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account = @family.ibkr_items.create!(
      name: "IBKR",
      query_id: "QUERY123",
      token: "TOKEN123"
    ).ibkr_accounts.create!(
      name: "Main",
      ibkr_account_id: "U1234567",
      currency: "CHF",
      current_balance: 3351,
      cash_balance: 1000.5,
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "3201.00" },
        { report_date: "2026-05-08", total: "3351.00" }
      ]
    )
    @ibkr_account.ensure_account_provider!(@account)
  end

  # Seed an existing balance row as if the materializer already ran.
  def seed_balance(date:, balance:, cash_balance:)
    non_cash = balance - cash_balance
    @account.balances.create!(
      date: date,
      balance: balance,
      cash_balance: cash_balance,
      currency: "CHF",
      start_cash_balance: cash_balance,
      start_non_cash_balance: non_cash,
      cash_inflows: 0,
      cash_outflows: 0,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: 0,
      cash_adjustments: 0,
      non_cash_adjustments: 0,
      flows_factor: 1
    )
  end

  test "overrides total from IBKR equity summary while preserving materializer cash split" do
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 900.50)
    seed_balance(date: Date.new(2026, 5, 8), balance: 3100.00, cash_balance: 1000.50)

    assert_no_difference "@account.entries.count" do
      IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!
    end

    first  = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    second = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")

    # Total overridden with IBKR's reported figure
    assert_equal BigDecimal("3201.00"), first.end_balance
    assert_equal BigDecimal("3351.00"), second.end_balance

    # Cash preserved from the materializer, not read from equity summary
    assert_equal BigDecimal("900.50"),  first.end_cash_balance
    assert_equal BigDecimal("1000.50"), second.end_cash_balance

    # Non-cash = IBKR total - materializer cash
    assert_equal BigDecimal("2300.50"), first.end_non_cash_balance
    assert_equal BigDecimal("2350.50"), second.end_non_cash_balance
  end

  test "uses zero cash when no prior materializer balance exists for a date" do
    # No existing balance rows — first-ever sync
    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_equal BigDecimal("3201.00"), balance.end_balance
    assert_equal BigDecimal("0"),       balance.end_cash_balance
    assert_equal BigDecimal("3201.00"), balance.end_non_cash_balance
  end

  test "accepts rows without a currency field (Flex configs that omit the attribute)" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "3201.00" }   # no currency key
      ]
    )
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 900.50)

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_equal BigDecimal("3201.00"), balance.end_balance
    assert_equal BigDecimal("900.50"),  balance.end_cash_balance
  end

  test "accepts rows when account currency casing differs from payload" do
    @ibkr_account.update!(currency: "chf")
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 900.50)

    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { currency: "CHF", report_date: "2026-05-07", total: "3201.00" }
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_equal BigDecimal("3201.00"), balance.end_balance
  end

  test "skips BASE_SUMMARY rows" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { currency: "BASE_SUMMARY", report_date: "2026-05-07", total: "9999.00" },
        { currency: "CHF",          report_date: "2026-05-07", total: "3201.00" }
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_equal BigDecimal("3201.00"), balance.end_balance
  end

  test "skips rows with a mismatched explicit currency" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { currency: "USD", report_date: "2026-05-07", total: "9999.00" },
        { currency: "CHF", report_date: "2026-05-07", total: "3201.00" }
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_equal BigDecimal("3201.00"), balance.end_balance
  end

  test "skips malformed rows and still imports valid ones" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        nil,
        "bad-row",
        [],
        { report_date: "2026-05-11", total: "3400.00" }
      ]
    )
    seed_balance(date: Date.new(2026, 5, 11), balance: 3300.00, cash_balance: 1100.50)

    assert_nothing_raised do
      IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!
    end

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 11), currency: "CHF")
    assert_equal BigDecimal("3400.00"), balance.end_balance
    assert_equal BigDecimal("1100.50"), balance.end_cash_balance
  end

  test "fills weekend and holiday gaps by carrying forward the last IBKR total with materializer cash" do
    # Simulate the real-world situation: IBKR has no weekend rows, and historical
    # holdings only cover the current snapshot so the materializer writes total=cash
    # for gap dates. HistoricalBalancesSync must write the correct total for those days.
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-08", total: "3351.00" },  # Friday
        # Saturday May 9 and Sunday May 10 absent — IBKR never sends them
        { report_date: "2026-05-11", total: "3400.00" }   # Monday
      ]
    )

    # Materializer computed correct cash for all dates; wrong total for the weekend
    seed_balance(date: Date.new(2026, 5, 8),  balance: 3351.00, cash_balance: 900.50)
    seed_balance(date: Date.new(2026, 5, 9),  balance: 900.50,  cash_balance: 900.50)  # wrong total
    seed_balance(date: Date.new(2026, 5, 10), balance: 900.50,  cash_balance: 900.50)  # wrong total
    seed_balance(date: Date.new(2026, 5, 11), balance: 3400.00, cash_balance: 910.00)

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    saturday = @account.balances.find_by!(date: Date.new(2026, 5, 9),  currency: "CHF")
    sunday   = @account.balances.find_by!(date: Date.new(2026, 5, 10), currency: "CHF")

    # Total corrected to Friday's IBKR total; cash preserved from materializer
    assert_equal BigDecimal("3351.00"), saturday.end_balance
    assert_equal BigDecimal("900.50"),  saturday.end_cash_balance
    assert_equal BigDecimal("2450.50"), saturday.end_non_cash_balance

    assert_equal BigDecimal("3351.00"), sunday.end_balance
    assert_equal BigDecimal("900.50"),  sunday.end_cash_balance
    assert_equal BigDecimal("2450.50"), sunday.end_non_cash_balance
  end

  test "skips rows with missing or unparseable total" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-06", total: "N/A" },   # unparseable string — before first valid date
        { report_date: "2026-05-07", total: nil },      # nil total
        { report_date: "2026-05-08", total: "3351.00" } # valid
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    # Gap-fill starts at the first valid trading day (May 8), so pre-range
    # dates with bad totals must not produce any balance row.
    assert_nil @account.balances.find_by(date: Date.new(2026, 5, 6), currency: "CHF")
    assert_nil @account.balances.find_by(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_not_nil @account.balances.find_by(date: Date.new(2026, 5, 8), currency: "CHF")
  end

  test "computes net_market_flows from equity delta minus trade flows" do
    # Day 1: total=3000, cash=500, non_cash=2500
    # Day 2: total=3200, cash=500, non_cash=2700  (Δnon_cash=200)
    #   Buy trade on Day 2: CHF 150 (same currency as account, no FX)
    #   nmf = 200 - 150 = 50
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "3000.00" },
        { report_date: "2026-05-08", total: "3200.00" }
      ]
    )
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 500.00)
    seed_balance(date: Date.new(2026, 5, 8), balance: 3200.00, cash_balance: 500.00)

    security = Security.create!(ticker: "TEST", name: "Test Stock")
    @account.entries.create!(
      name: "Buy 100 TEST",
      date: Date.new(2026, 5, 8),
      amount: 150.00,
      currency: "CHF",
      entryable: Trade.new(security: security, qty: 100, price: 1.5, currency: "CHF")
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    day1 = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    day2 = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")

    assert_equal BigDecimal("0"),   day1.net_market_flows
    assert_equal BigDecimal("50"),  day2.net_market_flows

    # Virtual column must still resolve to IBKR's equity total minus cash
    assert_equal BigDecimal("2500.00"), day1.end_non_cash_balance
    assert_equal BigDecimal("2700.00"), day2.end_non_cash_balance
  end

  test "applies fx_rate_to_base when trade currency differs from account currency" do
    # Trade in EUR with fx_rate_to_base=1.1 → CHF 165, not CHF 150
    # Day 1: non_cash=2500, Day 2: non_cash=2700 (Δ=200)
    # nmf = 200 - 165 = 35
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "3000.00" },
        { report_date: "2026-05-08", total: "3200.00" }
      ]
    )
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 500.00)
    seed_balance(date: Date.new(2026, 5, 8), balance: 3200.00, cash_balance: 500.00)

    security = Security.create!(ticker: "TEST2", name: "Test Stock EUR")
    trade = Trade.new(security: security, qty: 100, price: 1.5, currency: "EUR")
    trade.exchange_rate = 1.1
    @account.entries.create!(
      name: "Buy 100 TEST2",
      date: Date.new(2026, 5, 8),
      amount: 150.00,
      currency: "EUR",
      entryable: trade
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    day2 = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")
    assert_in_delta 35.0, day2.net_market_flows.to_f, 0.01
    assert_equal BigDecimal("2700.00"), day2.end_non_cash_balance
  end

  test "excludes balance row from upsert when Money::ConversionError prevents FX conversion" do
    # EUR trade with no exchange_rate stored → custom_rate=nil → ConversionError raised.
    # The affected date is excluded from the upsert entirely so net_market_flows is not
    # silently wrong (the trade's value would otherwise flow into market appreciation).
    # The seeded day2 balance is intentionally different from IBKR's total (3150 vs 3200)
    # so we can assert the row was not overwritten by sync.
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "3000.00" },
        { report_date: "2026-05-08", total: "3200.00" }
      ]
    )
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 500.00)
    seed_balance(date: Date.new(2026, 5, 8), balance: 3150.00, cash_balance: 500.00)

    security = Security.create!(ticker: "NORATE", name: "No Rate EUR Stock")
    @account.entries.create!(
      name: "Buy 100 NORATE",
      date: Date.new(2026, 5, 8),
      amount: 150.00,
      currency: "EUR",
      entryable: Trade.new(security: security, qty: 100, price: 1.5, currency: "EUR")
    )

    Money.any_instance.stubs(:exchange_to).raises(
      Money::ConversionError.new(from_currency: "EUR", to_currency: "CHF", date: Date.new(2026, 5, 8))
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    # Day 1 is unaffected — still synced normally
    day1 = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_equal BigDecimal("3000.00"), day1.balance

    # Day 2 was excluded from the upsert — seeded values are preserved, not overwritten
    day2 = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")
    assert_equal BigDecimal("3150.00"), day2.balance          # seeded, not IBKR's 3200
    assert_equal BigDecimal("0"),       day2.net_market_flows  # seeded, not recomputed
  end

  test "net_market_flows equals full non_cash delta when account has no trades" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "3000.00" },
        { report_date: "2026-05-08", total: "3300.00" }
      ]
    )
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 500.00)
    seed_balance(date: Date.new(2026, 5, 8), balance: 3300.00, cash_balance: 500.00)

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    day1 = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    day2 = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")

    assert_equal BigDecimal("0"),   day1.net_market_flows
    assert_equal BigDecimal("300"), day2.net_market_flows
    assert_equal BigDecimal("2800.00"), day2.end_non_cash_balance
  end

  test "sell trades reduce net_buy_sell so market loss is isolated in net_market_flows" do
    # Day 1: total=3000, cash=500, non_cash=2500
    # Day 2: total=2700, cash=700, non_cash=2000 (Δnon_cash=-500)
    #   Sell 100 at CHF 1.50: entry.amount=-150 (negative = proceeds received)
    #   net_buy_sell=-150; nmf = -500 - (-150) = -350 (market caused -350 loss)
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "3000.00" },
        { report_date: "2026-05-08", total: "2700.00" }
      ]
    )
    seed_balance(date: Date.new(2026, 5, 7), balance: 3000.00, cash_balance: 500.00)
    seed_balance(date: Date.new(2026, 5, 8), balance: 2700.00, cash_balance: 700.00)

    security = Security.create!(ticker: "SELL_TEST", name: "Sell Test Stock")
    @account.entries.create!(
      name: "Sell 100 SELL_TEST",
      date: Date.new(2026, 5, 8),
      amount: -150.00,
      currency: "CHF",
      entryable: Trade.new(security: security, qty: -100, price: 1.5, currency: "CHF")
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    day2 = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")
    assert_equal BigDecimal("-350"), day2.net_market_flows
    assert_equal BigDecimal("2000.00"), day2.end_non_cash_balance
  end

  test "writes balance row with zero total for fully liquidated dates" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "0"      },
        { report_date: "2026-05-08", total: "3351.00" }
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_equal BigDecimal("0"), balance.end_balance
  end
end
