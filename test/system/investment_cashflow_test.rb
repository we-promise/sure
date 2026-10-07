require "application_system_test_case"

class InvestmentCashflowSystemTest < ApplicationSystemTestCase
  include EntriesTestHelper

  test "correct an unmatched brokerage paycheck and preserve it across reload" do
    user = users(:family_admin)
    deposit = create_transaction(account: accounts(:investment), amount: -3000, name: "Payroll deposit", kind: "investment_contribution")
    deposit.transaction.update!(investment_activity_label: "Contribution")
    sign_in user
    visit transaction_path(deposit)
    find("summary", text: /settings/i).click
    assert_button "Treat as income"
    page.save_screenshot(ENV["INVESTMENT_CORRECTION_SCREENSHOT_PATH"]) if ENV["INVESTMENT_CORRECTION_SCREENSHOT_PATH"].present?
    click_button "Treat as income"
    assert_no_selector "form[action='#{correct_as_income_transaction_path(deposit)}']", visible: :all
    assert_equal "standard", deposit.reload.transaction.kind
    assert_nil deposit.transaction.investment_activity_label
    assert deposit.user_modified?
    visit transaction_path(deposit)
    assert_no_button "Treat as income"
    assert_field "Name", with: "Payroll deposit"
    page.save_screenshot(ENV["INVESTMENT_SCREENSHOT_PATH"]) if ENV["INVESTMENT_SCREENSHOT_PATH"].present?
  end

  test "invested money has its own chart flow rather than an expense category" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    date = Date.new(2026, 8, 10)
    account = accounts(:depository)
    create_transaction(account: account, amount: -4200, name: "Salary", date: date, category: categories(:income))
    create_transaction(account: account, amount: 100, name: "Food", date: date, category: categories(:food_and_drink))
    create_transaction(account: account, amount: 2000, name: "Investing", date: date, kind: "investment_contribution")
    sign_in user
    visit root_path(start_date: date.beginning_of_month.iso8601, end_date: date.end_of_month.iso8601)
    assert_selector "#cashflow-preview g[aria-label='Invested, $2,000.00']"
    assert_selector "#cashflow-preview svg .sankey-link"
    if ENV["INVESTMENT_CHART_SCREENSHOT_PATH"].present?
      page.save_screenshot(ENV["INVESTMENT_CHART_SCREENSHOT_PATH"])
    end
  end
end
