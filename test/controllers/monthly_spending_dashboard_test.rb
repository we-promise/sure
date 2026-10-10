require "test_helper"

class MonthlySpendingDashboardTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "preview block renders after money flow with responsive chart and category details" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    get root_url
    assert_response :success
    assert_select "#monthly-spending-section", count: 1
    assert_select "[data-controller='DS--monthly-spending-chart']", count: 1
    assert_select "#monthly-spending-section table"
    assert_select "#monthly-spending-section input[name='monthly_spending_account_ids[]'][type=hidden]", count: 1
    assert_operator response.body.index('id="money-flow-section"'), :<, response.body.index('id="monthly-spending-section"')
  end

  test "feature and hidden list are absent without personal preview access" do
    @user.update!(preferences: { "preview_features_enabled" => false, "hidden_sections" => [ "monthly_spending" ] })
    IncomeStatement::MonthlySpending.expects(:new).never
    get root_url, params: { customize: "true" }
    assert_response :success
    assert_select "#monthly-spending-section", count: 0
    assert_select "[value='monthly_spending']", count: 0
  end

  test "empty and invalid filters never show unfiltered bars" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    get root_url, params: { monthly_spending_account_ids: [ "" ] }
    assert_response :success
    assert_select "#monthly-spending-section [data-controller='DS--monthly-spending-chart']", count: 0
    get root_url, params: { monthly_spending_from: "invalid" }
    assert_response :success
    assert_select "#monthly-spending-section [data-controller='DS--monthly-spending-chart']", count: 0
    assert_select "#monthly-spending-section [role='status']"
  end

  test "single digit month is normalized without silently changing the period" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    travel_to Date.new(2026, 10, 10) do
      create_transaction(account: accounts(:depository), date: Date.new(2025, 2, 1), amount: 25)
      get root_url, params: { monthly_spending_from: "2025-2", monthly_spending_to: "2025-04" }
      assert_response :success
      assert_select "select[name='monthly_spending_from_month'] option[selected][value='2']"
      assert_select "select[name='monthly_spending_from_year'] option[selected][value='2025']"
      assert_select "[data-monthly-spending-total]", count: 3
      assert_select "[data-monthly-spending-total='2025-02-01']"
    end
  end

  test "invalid range retains date and account selections for correction" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    travel_to Date.new(2026, 10, 10) do
      get root_url, params: {
        monthly_spending_from_year: "2026", monthly_spending_from_month: "2",
        monthly_spending_to_year: "2025", monthly_spending_to_month: "11",
        monthly_spending_account_ids: [ "" ]
      }
      assert_response :success
      assert_select "select[name='monthly_spending_from_month'] option[selected][value='2']"
      assert_select "select[name='monthly_spending_from_year'] option[selected][value='2026']"
      assert_select "select[name='monthly_spending_to_month'] option[selected][value='11']"
      assert_select "input[name='monthly_spending_account_ids[]'][checked]", count: 0
      assert_select "[data-monthly-spending-total]", count: 0
    end
  end
end
