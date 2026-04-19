# frozen_string_literal: true

require "test_helper"

class Settings::AiPromptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    sign_in @user
    @family = @user.family
  end

  test "show requires admin" do
    sign_in users(:family_member)
    get settings_ai_prompts_url
    assert_redirected_to root_path
    assert_match(/not authorized/i, flash[:alert].to_s)
  end

  test "update requires admin" do
    sign_in users(:family_member)
    patch settings_ai_prompts_url, params: { family: { preferred_ai_model: "gpt-4" } }
    assert_redirected_to root_path
    assert_match(/not authorized/i, flash[:alert].to_s)
  end

  test "show renders and includes assistant prompt content" do
    get settings_ai_prompts_url
    assert_response :success
    assert_match(/Prompt instructions|Main System Prompt/, response.body)
  end

  test "update saves preferred model" do
    patch settings_ai_prompts_url, params: {
      family: { preferred_ai_model: "gpt-4-turbo" }
    }
    assert_redirected_to settings_ai_prompts_path
    assert_equal "gpt-4-turbo", @family.reload.preferred_ai_model
  end

  test "update saves per-family OpenAI endpoint and model" do
    patch settings_ai_prompts_url, params: {
      family: {
        openai_uri_base: "https://api.example.com/v1",
        preferred_ai_model: "gpt-4-turbo"
      }
    }
    assert_redirected_to settings_ai_prompts_path
    @family.reload
    assert_equal "https://api.example.com/v1", @family.openai_uri_base
    assert_equal "gpt-4-turbo", @family.preferred_ai_model
  end

  test "update with endpoint but no model returns unprocessable" do
    patch settings_ai_prompts_url, params: {
      family: { openai_uri_base: "https://api.example.com/v1", preferred_ai_model: "" }
    }
    assert_response :unprocessable_entity
    assert @family.reload.openai_uri_base.blank?
  end

  test "update with blank params clears overrides" do
    @family.update!(preferred_ai_model: "gpt-4", openai_uri_base: "https://api.example.com/v1")
    patch settings_ai_prompts_url, params: {
      family: {
        preferred_ai_model: "",
        openai_uri_base: ""
      }
    }
    assert_redirected_to settings_ai_prompts_path
    @family.reload
    assert @family.preferred_ai_model.blank?
    assert @family.openai_uri_base.blank?
  end
end
