require "application_system_test_case"

class CashFlowGroupByTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @month = Date.current.beginning_of_month
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    category = @user.family.categories.create!(name: "Group By Shopping", color: "#123456")
    account = @user.family.accounts.create!(name: "Group By Checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: account, category: category, amount: 100, date: @month)
  end

  test "switching the preview Sankey to flows by account redraws it and is remembered" do
    sign_in @user
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-preview [data-preview-sankey-chart-target='chart']", match: :first)
    assert_selector "#cashflow-preview svg .sankey-link"
    assert_no_selector "#cashflow-preview svg text", text: "Group By Checking"

    within("#cashflow-preview") { click_button "Account" }

    chart.assert_selector "svg text", text: "Group By Checking"
    assert_selector "#cashflow-preview button[aria-pressed='true']", text: "Account"
    assert_nil find("#cashflow-preview")["data-sankey-comparison"].presence, "only the category view is compared with the legacy chart"

    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    find("#cashflow-preview [data-preview-sankey-chart-target='chart']", match: :first)
      .assert_selector "svg text", text: "Group By Checking"
    assert_equal "account", @user.reload.cashflow_sankey_group_by
  end
end
