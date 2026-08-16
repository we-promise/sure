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
    refute result[:holdings].any? { |holding| holding[:value_unavailable] }
  end

  test "unconvertible holdings are flagged and excluded from total_value" do
    account = @family.accounts.create!(
      name: "FX Gap Brokerage",
      balance: 10000,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new,
      owner: @user
    )

    usd_security = Security.create!(ticker: "USDG", name: "USD Holding")
    jpy_security = Security.create!(ticker: "JPYG", name: "JPY Holding")

    account.holdings.create!(
      security: usd_security,
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )
    account.holdings.create!(
      security: jpy_security,
      date: Date.current,
      qty: 1,
      price: 10_000,
      amount: 10_000,
      currency: "JPY"
    )

    result = @function.call("page" => 1, "accounts" => [ account.name ])

    assert_equal Money.new(100, @family.currency).format, result[:total_value]
    assert_equal 2, result[:total_results]

    jpy_row = result[:holdings].find { |holding| holding[:ticker] == "JPYG" }
    usd_row = result[:holdings].find { |holding| holding[:ticker] == "USDG" }

    assert jpy_row[:value_unavailable]
    assert_nil jpy_row[:weight]
    assert_equal 10_000.0, jpy_row[:amount]

    refute usd_row.key?(:value_unavailable)
    assert usd_row.key?(:weight)
    assert_equal "USDG", result[:holdings].first[:ticker],
                 "Convertible holdings should sort ahead of unknown FX"
  end
end
