require "test_helper"

class CashFlowVisualizationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    Rails.configuration.x.posthog.stubs(:development_enabled).returns(false)
  end

  test "one cash flow visualization is available regardless of preview opt-in" do
    [ false, true ].each do |enabled|
      @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => enabled))
      get root_path
      assert_response :success
      assert_select "[data-controller~='sankey-visualization']", count: 1
      assert_select "[data-controller='cash-flow']", count: 1
      assert_select "[data-controller='sankey-chart']", count: 2
      assert_select "[data-sankey-visualization-survey-id-value]", count: 0
      assert_select "[data-sankey-comparison]", count: 0
      assert_select "#cashflow-sankey-feedback-dialog", count: 0
      assert_select "[data-sankey-visualization-target='expandButton'][aria-label='Expand']", count: 1
    end
  end

  test "self-hosted display tracking respects environment and operator opt-out" do
    config = Rails.configuration.x.posthog
    config.stubs(:api_key).returns(nil)
    config.stubs(:feedback_enabled).returns(true)
    with_self_hosting do
      get root_path
      assert_select "[data-sankey-visualization-feedback-key-value='']"
      Rails.env.stubs(:production?).returns(true)
      get root_path
      assert_select "[data-sankey-visualization-feedback-key-value^='phc_']"
      config.stubs(:feedback_enabled).returns(false)
      get root_path
      assert_select "[data-sankey-visualization-feedback-key-value='']"
    end
  end
end
