require "test_helper"

# Proves what the day-detail "Details" popup (UI::Account::BalanceReconciliation)
# shows for a daily-waypoint (EnableBanking-style) account with a transaction on
# every waypoint day. Persists real balances and reads the actual PG generated
# columns through the real GUI component.
class Balance::WaypointGuiBreakdownTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def persist_and_load(account)
    calculated = Balance::ReverseCalculator.new(account).calculate
    account.balances.upsert_all(
      calculated.map { |b|
        b.attributes.slice(
          "date", "balance", "cash_balance", "currency",
          "start_cash_balance", "start_non_cash_balance",
          "cash_inflows", "cash_outflows",
          "non_cash_inflows", "non_cash_outflows",
          "net_market_flows", "cash_adjustments", "non_cash_adjustments",
          "flows_factor"
        ).merge("updated_at" => Time.now)
      },
      unique_by: %i[account_id date currency]
    )
    account.balances.order(:date).to_a
  end

  # Reads the three lines exactly as the GUI Details popup renders them.
  def gui_lines(balance, account)
    items = UI::Account::BalanceReconciliation.new(balance: balance, account: account).reconciliation_items
    {
      start:    items.find { |i| i[:style] == :start }[:value].amount,
      net_flow: items.find { |i| i[:style] == :flow  }[:value].amount,
      final:    items.find { |i| i[:style] == :final }[:value].amount
    }
  end

  def build_account
    create_account_with_ledger(
      account: { type: Depository, balance: 20000, cash_balance: 20000, currency: "USD" },
      entries: [
        { type: "current_anchor", date: Date.current, balance: 20000 },
        { type: "reconciliation", date: 1.day.ago,  balance: 19000 },
        { type: "transaction",    date: 1.day.ago,  amount: -1000 }, # +1000 deposit
        { type: "reconciliation", date: 2.days.ago, balance: 17000 },
        { type: "transaction",    date: 2.days.ago, amount: -2000 }, # +2000 deposit
        { type: "reconciliation", date: 3.days.ago, balance: 16000 },
        { type: "transaction",    date: 3.days.ago, amount: 500 },   # -500 expense
        # 4.days.ago is a GAP day: no waypoint, no transaction
        { type: "opening_anchor", date: 5.days.ago, balance: 15000 }
      ]
    )
  end

  # Hard assertions for the fix currently in the tree (derive-start).
  test "derive-start fix: Net cash flow preserved on every waypoint day and it reconciles" do
    account = build_account
    balances = persist_and_load(account).index_by(&:date)

    expectations = {
      1.day.ago.to_date  => { start: 18000, net_flow: 1000,  final: 19000 },
      2.days.ago.to_date => { start: 15000, net_flow: 2000,  final: 17000 },
      3.days.ago.to_date => { start: 16500, net_flow: -500,  final: 16000 }
    }

    expectations.each do |date, exp|
      g = gui_lines(balances[date], account)
      assert_equal exp[:start],    g[:start],    "Start balance wrong on #{date}"
      assert_equal exp[:net_flow], g[:net_flow], "Net cash flow wrong on #{date} (should NOT be zeroed)"
      assert_equal exp[:final],    g[:final],    "Final balance wrong on #{date}"
      assert_equal g[:start] + g[:net_flow], g[:final], "Breakdown does not reconcile on #{date}"
      refute_equal 0, g[:net_flow], "Net cash flow was zeroed on #{date} — transaction hidden"
    end
  end
end
