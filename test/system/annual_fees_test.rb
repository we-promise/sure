require "application_system_test_case"

class AnnualFeesTest < ApplicationSystemTestCase
  test "annual and upcoming fees use the family currency" do
    user = users(:family_admin)
    today = Date.current
    account = accounts(:credit_card)
    account.credit_card.update!(annual_fee: 100, annual_fee_month: today.month, annual_fee_day: today.day)
    account.family.accounts.create!(name: "Example euro card", balance: 0, currency: "EUR", owner: user,
                                    accountable: CreditCard.new(annual_fee: 100, annual_fee_month: today.month, annual_fee_day: today.day))
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: today, rate: 1.2)
    sign_in user

    visit annual_fees_path

    assert_selector ".privacy-sensitive", text: "$220.00", exact_text: true, count: 2
    assert_selector "[data-testid='annual-fees-table']", text: "Example euro card"
    page.save_screenshot(Rails.root.join("tmp/screenshots/annual-fees.png"))
  end
end
