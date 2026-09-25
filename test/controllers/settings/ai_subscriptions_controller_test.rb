require "test_helper"

class Settings::AiSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "shows the AI subscriptions settings page" do
    get settings_ai_subscriptions_path

    assert_response :success
    assert_select "h1", text: I18n.t("settings.ai_subscriptions.show.page_title")
    assert_includes response.body, I18n.t("settings.ai_subscriptions.show.codex.title")
  end

  test "requires an administrator" do
    sign_in users(:family_member)

    get settings_ai_subscriptions_path

    assert_response :redirect
  end
end
