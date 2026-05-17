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
  end

  test "skips rows with zero or missing total" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { report_date: "2026-05-07", total: "0"   },
        { report_date: "2026-05-07", total: nil   },
        { report_date: "2026-05-08", total: "3351.00" }
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    assert_nil @account.balances.find_by(date: Date.new(2026, 5, 7), currency: "CHF")
    assert_not_nil @account.balances.find_by(date: Date.new(2026, 5, 8), currency: "CHF")
  end
end
