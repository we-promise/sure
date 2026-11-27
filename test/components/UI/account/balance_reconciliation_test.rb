require "test_helper"

class UI::Account::BalanceReconciliationTest < ViewComponent::TestCase
  setup do
    @account = families(:empty).accounts.create!(
      name: "Wallet", balance: 6000, cash_balance: 0, currency: "USD", accountable: Crypto.new
    )
  end

  def crypto_balance(**flows)
    @account.balances.create!(
      date: Date.current, balance: 6000, cash_balance: flows.fetch(:end_cash, 0), currency: "USD",
      start_cash_balance: flows.fetch(:start_cash, 0), start_non_cash_balance: 5000,
      cash_inflows: flows.fetch(:cash_inflows, 0), cash_outflows: flows.fetch(:cash_outflows, 0),
      non_cash_inflows: flows.fetch(:non_cash_inflows, 0), non_cash_outflows: 0,
      net_market_flows: flows.fetch(:net_market_flows, 0), cash_adjustments: 0, non_cash_adjustments: 0,
      flows_factor: 1
    )
  end

  def lines_add_up?(balance)
    items = UI::Account::BalanceReconciliation.new(balance: balance, account: @account).reconciliation_items
    start = items.find { |item| item[:style] == :start }[:value]
    final = items.find { |item| item[:style] == :final }[:value]
    steps = items.select { |item| %i[flow adjustment].include?(item[:style]) }.sum(Money.new(0, "USD")) { |item| item[:value] }

    start + steps == final
  end

  test "a crypto day with a transfer in adds up" do
    # 1000 of coins transferred in at 950, and 50 of market movement.
    balance = crypto_balance(non_cash_inflows: 950, net_market_flows: 50)

    assert_equal Money.new(6000, "USD"), balance.end_balance_money
    assert lines_add_up?(balance)
  end
end
