require "test_helper"

class CashFlowPreviewTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "preview opt-in adds the web chart below identical legacy chart data" do
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
    assert_select "#cashflow-preview [data-cash-flow-url-value*='/dashboard/cash_flow?']", count: 1
    assert_equal legacy, css_select("[data-controller='sankey-chart']").map { |chart| chart["data-sankey-chart-data-value"] }
  end

  test "a family member's preview opt-in does not expose the preview to this user" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    @user.family.users.where.not(id: @user.id).first.update!(preferences: { "preview_features_enabled" => true })
    get root_path
    assert_response :success
    assert_select "#cashflow-preview", count: 0
  end

  test "self-hosted production preview needs no operator key or survey configuration" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    config = Rails.configuration.x.posthog
    config.stubs(:api_key).returns(nil)
    config.stubs(:sankey_survey_id).returns(nil)
    config.stubs(:feedback_enabled).returns(true)
    with_self_hosting do
      get root_path
      assert_select "#cashflow-preview[data-sankey-preview-self-hosted-value='true'][data-sankey-preview-feedback-key-value=''][data-sankey-preview-survey-id-value='']"
      Rails.env.stubs(:production?).returns(true)
      get root_path
      assert_select "#cashflow-preview[data-sankey-preview-feedback-key-value^='phc_'][data-sankey-preview-survey-id-value='01a0a162-73a2-0000-9402-ffab5bc45b4a']"
      config.stubs(:api_key).returns("operator-owned-project")
      config.stubs(:sankey_survey_id).returns("operator-owned-survey")
      get root_path
      assert_select "#cashflow-preview[data-sankey-preview-feedback-key-value^='phc_'][data-sankey-preview-survey-id-value='01a0a162-73a2-0000-9402-ffab5bc45b4a']"
      config.stubs(:feedback_enabled).returns(false)
      get root_path
      assert_select "#cashflow-preview[data-sankey-preview-feedback-key-value=''][data-sankey-preview-survey-id-value='']"
    end
  end

  test "managed app and demo use the configured environment survey without the shared feedback client" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    Rails.env.stubs(:production?).returns(true)
    config = Rails.configuration.x.posthog
    [ "app-survey", "demo-survey" ].each do |survey_id|
      config.stubs(:sankey_survey_id).returns(survey_id)
      get root_path
      assert_select "#cashflow-preview[data-sankey-preview-self-hosted-value='false'][data-sankey-preview-feedback-key-value=''][data-sankey-preview-survey-id-value='#{survey_id}']"
    end
  end
end
