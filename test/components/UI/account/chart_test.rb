require "test_helper"

class UI::Account::ChartTest < ViewComponent::TestCase
  setup do
    @account = accounts(:investment)
    @account.holdings.destroy_all
  end

  test "renders positive gains with explicit plus sign" do
    create_holding(cost_basis: 90)

    render_inline(UI::Account::Chart.new(account: @account, view: "gains"))

    assert_text "+$100.00"
  end

  test "does not sign non-gains views" do
    component = UI::Account::Chart.new(account: @account, view: "balance")

    assert_equal @account.balance_money.format, component.view_balance_display
    refute component.view_balance_display.start_with?("+")
  end

  test "negative gains keep plain money formatting" do
    create_holding(cost_basis: 110)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "-$100.00", component.view_balance_display
  end

  test "converted amount is signed like the main indicator for foreign-currency accounts" do
    @account.update!(currency: "EUR")
    create_holding(cost_basis: 90)
    ExchangeRate.create!(date: Date.current, from_currency: "EUR", to_currency: "USD", rate: 1.1)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "+€100.00", component.view_balance_display
    assert_equal "+$110.00", component.converted_balance_display
  end

  test "cash-equivalent holdings are displayed as cash instead of holdings" do
    @account.update!(balance: 6500, cash_balance: 1000, currency: "USD")
    @account.holdings.create!(security: securities(:aapl), date: Date.current, qty: 15, price: 100, amount: 1500, currency: "USD")
    @account.holdings.create!(security: Security.create!(ticker: "SPAXX", name: "Money Market Fund"), date: Date.current, qty: 4000, price: 1, amount: 4000, currency: "USD", cash_equivalent: true)

    component = UI::Account::Chart.new(account: @account, view: "cash_balance")

    assert_equal Money.new(1500, "USD"), component.holdings_value_money
    assert_equal Money.new(5000, "USD"), component.cash_balance_money
    assert_equal Money.new(5000, "USD"), component.view_balance_money
  end

  private
    # 10 shares at $100 market price; gain = 1000 - cost_basis * 10
    def create_holding(cost_basis:)
      Holding.create!(
        account: @account,
        security: securities(:aapl),
        date: Date.current,
        qty: 10,
        price: 100,
        amount: 1000,
        currency: @account.currency,
        cost_basis: cost_basis
      )
    end
end
