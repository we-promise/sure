require "test_helper"

class Settings::AiPromptsControllerTest < ActionDispatch::IntegrationTest
  test "admin can view family AI prompts" do
    sign_in users(:family_admin)
    get settings_ai_prompts_path
    assert_response :success
  end

  test "non-admin member cannot view family AI prompts" do
    sign_in users(:family_member)
    get settings_ai_prompts_path
    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
  end

  test "guest cannot view family AI prompts" do
    sign_in users(:intro_user)
    get settings_ai_prompts_path
    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
  end
end
