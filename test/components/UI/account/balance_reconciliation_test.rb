require "test_helper"
require "ostruct"

class UI::Account::BalanceReconciliationTest < ViewComponent::TestCase
  test "preference negates all balance fields but leaves movement and adjustment values unchanged" do
    account = accounts(:other_liability)
    user = users(:family_admin)
    user.update!(preferences: { "negative_liability_balances" => true })
    Current.session = sessions(:one)

    balance = OpenStruct.new(
      start_balance_money: Money.new(1_000, "USD"),
      cash_inflows_money: Money.new(60, "USD"),
      cash_outflows_money: Money.new(30, "USD"),
      end_balance_money: Money.new(900, "USD"),
      cash_adjustments: 10,
      non_cash_adjustments: 0,
      cash_adjustments_money: Money.new(10, "USD"),
      non_cash_adjustments_money: Money.new(0, "USD")
    )

    render_inline(UI::Account::BalanceReconciliation.new(balance: balance, account: account))

    values = page.all("dd").map { |element| element.text.strip }
    assert_equal [ "-$1,000.00", "$30.00", "-$890.00", "$10.00", "-$900.00" ], values
  ensure
    Current.reset
  end
end
