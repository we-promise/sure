require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::GetHoldings.new(@user)
  end

  test "total_value converts mixed-currency holdings into family currency" do
    account = @family.accounts.create!(
      name: "Mixed Brokerage",
      balance: 10000,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new,
      owner: @user
    )

    usd_security = Security.create!(ticker: "USDH", name: "USD Holding")
    eur_security = Security.create!(ticker: "EURH", name: "EUR Holding")

    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 1.25)

    account.holdings.create!(
      security: usd_security,
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )
    account.holdings.create!(
      security: eur_security,
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "EUR"
    )

    result = @function.call("page" => 1, "accounts" => [ account.name ])

    # 100 USD + (100 EUR * 1.25) = 225 family currency (USD for dylan_family)
    assert_equal Money.new(225, @family.currency).format, result[:total_value]
    assert_equal 2, result[:total_results]
  end
end
