# frozen_string_literal: true

require "test_helper"

class Settings::AiPromptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    sign_in @user
    @family = @user.family
  end

  test "show renders and assigns assistant config" do
    get settings_ai_prompts_url
    assert_response :success
    assert_not_nil assigns(:assistant_config)
    assert assigns(:assistant_config).key?(:instructions)
  end

  test "update saves custom prompts and preferred model" do
    patch settings_ai_prompts_url, params: {
      family: {
        preferred_ai_model: "gpt-4-turbo",
        custom_system_prompt: "You are a helpful assistant.",
        custom_intro_prompt: "Welcome! Tell me about yourself."
      }
    }
    assert_redirected_to settings_ai_prompts_path
    @family.reload
    assert_equal "gpt-4-turbo", @family.preferred_ai_model
    assert_equal "You are a helpful assistant.", @family.custom_system_prompt
    assert_equal "Welcome! Tell me about yourself.", @family.custom_intro_prompt
  end

  test "update with invalid length returns unprocessable and preserves errors" do
    long_prompt = "x" * (Family::CUSTOM_PROMPT_MAX_LENGTH + 1)
    patch settings_ai_prompts_url, params: {
      family: { custom_system_prompt: long_prompt }
    }
    assert_response :unprocessable_entity
    assert_template :show
    @family.reload
    assert @family.errors[:custom_system_prompt].any?
  end

  test "update with blank params clears overrides" do
    @family.update!(
      preferred_ai_model: "gpt-4",
      custom_system_prompt: "Custom",
      custom_intro_prompt: "Intro"
    )
    patch settings_ai_prompts_url, params: {
      family: {
        preferred_ai_model: "",
        custom_system_prompt: "",
        custom_intro_prompt: ""
      }
    }
    assert_redirected_to settings_ai_prompts_path
    @family.reload
    assert @family.preferred_ai_model.blank?
    assert @family.custom_system_prompt.blank?
    assert @family.custom_intro_prompt.blank?
  end
end
