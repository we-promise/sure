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

  test "admin can update family AI prompts" do
    admin = users(:family_admin)
    sign_in admin

    patch settings_ai_prompts_path, params: { family: { ai_prompt_chat_system: "Be terse." } }

    assert_redirected_to settings_ai_prompts_path
    assert_equal "Be terse.", admin.family.reload.ai_prompt(:chat_system)
  end

  test "a blank prompt resets the family back to the built-in default" do
    admin = users(:family_admin)
    admin.family.update!(ai_prompt_chat_system: "Be terse.")
    sign_in admin

    patch settings_ai_prompts_path, params: { family: { ai_prompt_chat_system: "" } }

    assert_redirected_to settings_ai_prompts_path
    assert_nil admin.family.reload.ai_prompt(:chat_system)
  end

  test "non-admin member cannot update family AI prompts" do
    member = users(:family_member)
    sign_in member

    patch settings_ai_prompts_path, params: { family: { ai_prompt_chat_system: "Be terse." } }

    assert_redirected_to accounts_path
    assert_nil member.family.reload.ai_prompt(:chat_system)
  end

  test "rejects a prompt over the length cap and re-renders the form" do
    admin = users(:family_admin)
    sign_in admin

    patch settings_ai_prompts_path, params: {
      family: { ai_prompt_chat_system: "x" * (Family::AiPromptable::MAX_LENGTH + 1) }
    }

    assert_response :unprocessable_entity
    assert_nil admin.family.reload.ai_prompt(:chat_system)
  end
end
