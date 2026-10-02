require "test_helper"

class DailyWebUsageRenderingTest < ActionDispatch::IntegrationTest
  setup do
    ApplicationController.view_context_class.any_instance.stubs(:daily_web_usage_enabled?).returns(true)
  end

  test "authenticated layouts expose the current user's preview Boolean for local counting" do
    user = users(:family_admin)
    sign_in user
    get settings_preferences_url

    assert_select ".ph-no-capture[data-controller='daily-web-usage'][hidden]", count: 1 do |nodes|
      assert_equal user.id, nodes.first["data-daily-web-usage-account-id-value"]
      assert_equal "false", nodes.first["data-daily-web-usage-preview-features-enabled-value"]
    end

    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    get settings_preferences_url
    assert_select "[data-controller='daily-web-usage'][data-daily-web-usage-preview-features-enabled-value='true']", count: 1
  end

  test "logged-out pages do not render the tracker" do
    get new_session_url
    assert_select "[data-controller='daily-web-usage']", count: 0
  end

  test "disabled analytics does not render the tracker for an authenticated user" do
    ApplicationController.view_context_class.any_instance.stubs(:daily_web_usage_enabled?).returns(false)
    sign_in users(:family_admin)
    get settings_preferences_url
    assert_select "[data-controller='daily-web-usage']", count: 0
  end
end
