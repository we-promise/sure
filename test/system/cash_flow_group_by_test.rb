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

  test "the account view draws a card paid off from another account as a flow between them" do
    family = @user.family
    salary = family.categories.create!(name: "Group By Salary", color: "#00aa00")
    checking = family.accounts.find_by!(name: "Group By Checking")
    card = family.accounts.create!(name: "Group By Card", currency: "USD", balance: 0, accountable: CreditCard.new)
    create_transaction(account: checking, category: salary, amount: -1000, date: @month)
    create_transaction(account: card, category: family.categories.find_by!(name: "Group By Shopping"), amount: 250, date: @month)
    create_transfer(from_account: checking, to_account: card, amount: 250, date: @month)
    @user.update!(preferences: @user.preferences.merge("cashflow_sankey_group_by" => "account"))

    sign_in @user
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-preview [data-preview-sankey-chart-target='chart']", match: :first)

    chart.assert_selector "svg text", text: "Group By Card"
    flows = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#cashflow-preview svg .sankey-link"))
        .map((path) => path.__data__)
        .map((link) => [link.source.name, link.target.name, link.value])
    JS
    assert_includes flows, [ "Group By Checking", "Group By Card", 250 ]
    assert_not(flows.any? { |source, target, _| source == "Deficit" && target == "Group By Card" }, "the card is paid from Checking, not Deficit")
  end
end
