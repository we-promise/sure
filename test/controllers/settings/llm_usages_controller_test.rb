require "test_helper"

class Settings::LlmUsagesControllerTest < ActionDispatch::IntegrationTest
  test "admin can view family LLM usage" do
    sign_in users(:family_admin)
    get settings_llm_usage_path
    assert_response :success
  end

  test "non-admin member cannot view family LLM usage" do
    sign_in users(:family_member)
    get settings_llm_usage_path
    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
  end

  test "guest cannot view family LLM usage" do
    sign_in users(:intro_user)
    get settings_llm_usage_path
    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
  end
end
