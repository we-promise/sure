require "test_helper"

class CashFlowPreviewTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "preview opt-in adds the API chart below identical legacy chart data" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    get root_path
    assert_response :success
    assert_select "#cashflow-preview", count: 0
    assert_select "[data-controller='cash-flow']", count: 0
    legacy = css_select("[data-controller='sankey-chart']").map { |chart| chart["data-sankey-chart-data-value"] }
    assert_equal 2, legacy.length

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    get root_path
    assert_response :success
    assert_select "#cashflow-sankey-chart + #cashflow-preview", count: 1
    assert_select "#cashflow-preview [data-controller='preview-sankey-chart']", count: 2
    assert_select "#cashflow-preview [data-cash-flow-url-value*='/api/v1/cash_flow?']", count: 1
    assert_equal legacy, css_select("[data-controller='sankey-chart']").map { |chart| chart["data-sankey-chart-data-value"] }
  end

  test "a family member's preview opt-in does not expose the preview to this user" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    @user.family.users.where.not(id: @user.id).first.update!(preferences: { "preview_features_enabled" => true })
    get root_path
    assert_response :success
    assert_select "#cashflow-preview", count: 0
  end
end
