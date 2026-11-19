require "application_system_test_case"

class InvestmentContributionsAndGrantsTest < ApplicationSystemTestCase
  test "adds a contribution and updates principal" do
    account = accounts(:investment)
    account.investment.update!(subtype: "401k")
    sign_in users(:family_admin)
    visit account_path(account, tab: "contributions")

    within("[data-testid='principal-tab']") do
      fill_in "account_contribution[date]", with: Date.current
      fill_in "account_contribution[amount]", with: "500"
      click_button "Add"
    end

    assert_selector "[data-testid='principal-tab'] .privacy-sensitive", text: "$500.00"
    assert_equal 500, account.account_contributions.sum(:amount)
    page.save_screenshot(Rails.root.join("tmp/screenshots/account-contributions.png"))
  end

  test "shows mixed currency grant values in the account currency" do
    account = accounts(:investment)
    account.investment.update!(subtype: "stock_plan")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)
    [ [ "ACME", "USD", 10 ], [ "EXAMPLE", "EUR", 20 ] ].each do |ticker, currency, price|
      security = Security.create!(ticker: ticker, name: ticker)
      security.prices.create!(date: Date.current, price: price, currency: currency)
      grant = account.equity_grants.create!(ticker: ticker, total_units: 10)
      grant.vests.create!(vest_date: 1.month.from_now.to_date, units: 10)
    end
    sign_in users(:family_admin)

    visit account_path(account, tab: "grants")

    assert_selector "[data-testid='grants-tab'] .privacy-sensitive", text: "$400.00", exact_text: true, count: 2
    page.save_screenshot(Rails.root.join("tmp/screenshots/equity-grants.png"))
  end
end
