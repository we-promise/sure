require "test_helper"

class UI::Account::BalanceReconciliationTest < ViewComponent::TestCase
  test "a payment into an other liability shows as a decrease in its balance" do
    account = accounts(:other_liability)
    balance = account.balances.create!(
      date: Date.current, currency: "USD", balance: 2000,
      start_non_cash_balance: 2500, non_cash_inflows: 500, flows_factor: -1
    )

    flow = flow_item(account, balance)

    assert_equal Money.new(-500, "USD"), flow[:value]
    assert_equal Money.new(2000, "USD"), balance.reload.end_balance_money
  end

  test "a transfer into an other asset shows as an increase in its balance" do
    account = accounts(:other_asset)
    balance = account.balances.create!(
      date: Date.current, currency: "USD", balance: 1000,
      start_non_cash_balance: 500, non_cash_inflows: 500, flows_factor: 1
    )

    assert_equal Money.new(500, "USD"), flow_item(account, balance)[:value]
  end

  private
    def flow_item(account, balance)
      UI::Account::BalanceReconciliation.new(balance: balance, account: account)
        .reconciliation_items.find { |item| item[:style] == :flow }
    end
end
