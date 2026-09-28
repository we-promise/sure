require "application_system_test_case"

class CashflowSankeyAccountsViewTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    category = @user.family.categories.create!(name: "Accounts View Spend", color: "#FF5733")
    create_transaction(account: accounts(:depository), name: "Accounts view spend", amount: 75, category: category)
    page.current_window.resize_to(1400, 1000)
  end

  test "switching the Sankey to show flows by account" do
    visit root_path
    assert_selector "[data-sankey-chart-target='chart'] svg .sankey-link"

    section = find("section[data-section-key='cashflow_sankey']")
    section.hover
    section.find("summary[aria-label]").click
    section.find("[data-controller='cashflow-sankey-view']").click_button "Account"

    assert_selector "[data-controller='cashflow-sankey-view'] button[data-view='accounts'][aria-pressed='true']", visible: :all
    assert_selector "[data-sankey-chart-target='chart'] svg text", text: accounts(:depository).name
    assert_equal "accounts", @user.reload.cashflow_sankey_view
  end

  test "the view switch is reachable on a phone-sized screen" do
    page.current_window.resize_to(390, 844)
    visit root_path
    assert_selector "[data-sankey-chart-target='chart'] svg .sankey-link"

    section = find("section[data-section-key='cashflow_sankey']")
    section.find("summary[aria-label]").click
    section.find("[data-controller='cashflow-sankey-view']").click_button "Account"

    assert_selector "[data-controller='cashflow-sankey-view'] button[data-view='accounts'][aria-pressed='true']", visible: :all
    assert_equal "accounts", @user.reload.cashflow_sankey_view
  end
end
