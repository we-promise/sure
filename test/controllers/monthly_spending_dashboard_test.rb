require "test_helper"

class MonthlySpendingDashboardTest < ActionDispatch::IntegrationTest
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
end
