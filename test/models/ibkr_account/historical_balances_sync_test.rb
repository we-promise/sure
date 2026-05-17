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
        {
          currency: "CHF",
          report_date: "2026-05-07",
          cash: "900.50",
          stock: "2300.50",
          total: "3201.00"
        },
        {
          currency: "CHF",
          report_date: "2026-05-08",
          cash: "1000.50",
          stock: "2350.50",
          total: "3351.00"
        }
      ]
    )
    @ibkr_account.ensure_account_provider!(@account)
  end

  test "upserts historical balances without creating activity entries" do
    @account.balances.create!(
      date: Date.new(2026, 5, 7),
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      start_cash_balance: 0,
      start_non_cash_balance: 0,
      cash_inflows: 0,
      cash_outflows: 0,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: 0,
      cash_adjustments: 0,
      non_cash_adjustments: 0,
      flows_factor: 1
    )

    assert_no_difference "@account.entries.count" do
      IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!
    end

    first_balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    second_balance = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")

    assert_equal BigDecimal("3201.0"), first_balance.end_balance
    assert_equal BigDecimal("900.5"), first_balance.end_cash_balance
    assert_equal BigDecimal("2300.5"), first_balance.end_non_cash_balance

    assert_equal BigDecimal("3351.0"), second_balance.end_balance
    assert_equal BigDecimal("1000.5"), second_balance.end_cash_balance
    assert_equal BigDecimal("2350.5"), second_balance.end_non_cash_balance
    assert_equal BigDecimal("900.5"), second_balance.start_cash_balance
    assert_equal BigDecimal("2300.5"), second_balance.start_non_cash_balance
  end

  test "accepts equity summary rows when stored account currency casing differs" do
    @ibkr_account.update!(currency: "chf")

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    first_balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    second_balance = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")

    assert_equal BigDecimal("3201.0"), first_balance.end_balance
    assert_equal BigDecimal("3351.0"), second_balance.end_balance
  end

  test "skips malformed equity summary rows and still imports valid rows" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        nil,
        "bad-row",
        [],
        {
          currency: "CHF",
          report_date: "2026-05-11",
          cash: "1100.50",
          total: "3400.00"
        }
      ]
    )

    assert_nothing_raised do
      IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!
    end

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 11), currency: "CHF")

    assert_equal BigDecimal("3400.0"), balance.end_balance
    assert_equal BigDecimal("1100.5"), balance.end_cash_balance
    assert_equal BigDecimal("2299.5"), balance.end_non_cash_balance
  end

  test "ignores anomalous IBKR weekend rows and fills weekends from the preceding Friday instead" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        {
          currency: "CHF",
          report_date: "2026-05-08",
          cash: "1000.50",
          stock: "2350.50",
          total: "3351.00"
        },
        {
          currency: "CHF",
          report_date: "2026-05-09",
          cash: "3351.00",
          stock: "0.00",
          total: "3351.00"
        },
        {
          currency: "CHF",
          report_date: "2026-05-10",
          cash: "3351.00",
          stock: "0.00",
          total: "3351.00"
        },
        {
          currency: "CHF",
          report_date: "2026-05-11",
          cash: "1050.00",
          stock: "2400.00",
          total: "3450.00"
        }
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    friday   = @account.balances.find_by!(date: Date.new(2026, 5, 8),  currency: "CHF")
    saturday = @account.balances.find_by!(date: Date.new(2026, 5, 9),  currency: "CHF")
    sunday   = @account.balances.find_by!(date: Date.new(2026, 5, 10), currency: "CHF")
    monday   = @account.balances.find_by!(date: Date.new(2026, 5, 11), currency: "CHF")

    assert_equal BigDecimal("1000.5"), friday.end_cash_balance
    assert_equal BigDecimal("2350.5"), friday.end_non_cash_balance

    assert_equal BigDecimal("3351.0"), saturday.end_balance,
                 "Saturday carries Friday's total, not IBKR's anomalous all-cash value"
    assert_equal BigDecimal("1000.5"), saturday.end_cash_balance
    assert_equal BigDecimal("2350.5"), saturday.end_non_cash_balance

    assert_equal BigDecimal("3351.0"), sunday.end_balance
    assert_equal BigDecimal("1000.5"), sunday.end_cash_balance

    assert_equal BigDecimal("1050.0"), monday.end_cash_balance
    assert_equal BigDecimal("2400.0"), monday.end_non_cash_balance
    assert_equal BigDecimal("1000.5"), monday.start_cash_balance,
                 "Monday start values should carry from Friday, not from the anomalous Sunday"
    assert_equal BigDecimal("2350.5"), monday.start_non_cash_balance
  end

  test "fills weekends and exchange holidays by carrying forward the last known value" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { currency: "CHF", report_date: "2026-05-07", cash: "900.50",  total: "3201.00" },
        { currency: "CHF", report_date: "2026-05-08", cash: "1000.50", total: "3351.00" },
        # gap: May 9 (Sat), May 10 (Sun), May 11 (Mon holiday) all missing
        { currency: "CHF", report_date: "2026-05-12", cash: "1050.00", total: "3450.00" }
      ]
    )

    IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!

    [ Date.new(2026, 5, 9), Date.new(2026, 5, 10), Date.new(2026, 5, 11) ].each do |gap_date|
      gap_balance = @account.balances.find_by!(date: gap_date, currency: "CHF")
      assert_equal BigDecimal("3351.0"), gap_balance.end_balance,
                   "#{gap_date} (gap) should carry Friday May 8 balance"
      assert_equal BigDecimal("1000.5"), gap_balance.end_cash_balance
      assert_equal BigDecimal("2350.5"), gap_balance.end_non_cash_balance
    end

    tuesday = @account.balances.find_by!(date: Date.new(2026, 5, 12), currency: "CHF")
    assert_equal BigDecimal("1000.5"), tuesday.start_cash_balance,
                 "Next trading day start should reflect Friday's values, not a stale anchor"
    assert_equal BigDecimal("2350.5"), tuesday.start_non_cash_balance
  end
end
