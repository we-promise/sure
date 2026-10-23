require "test_helper"

class Settings::LlmUsagesControllerTest < ActionDispatch::IntegrationTest
  test "Russian usage statistics localize dates and preserve USD costs" do
    sign_in user = users(:family_admin)
    usage = user.family.llm_usages.create!(
      provider: "openai", model: "gpt-4.1", operation: "chat",
      prompt_tokens: 100, completion_tokens: 50, total_tokens: 150, estimated_cost: "1.2345"
    )
    get settings_llm_usage_path(locale: "ru")
    assert_response :success
    expected_cost = I18n.with_locale(:ru) do
      ApplicationController.helpers.number_to_currency(usage.estimated_cost, unit: "USD", precision: 4)
    end
    assert_select "tbody td", text: expected_cost
    assert_select "tbody td", text: I18n.with_locale(:ru) { I18n.l(usage.created_at, format: :long) }
  end

  test "admin can view family LLM usage" do
    sign_in users(:family_admin)
    get settings_llm_usage_path
    assert_response :success
    assert_includes response.body, I18n.l(LlmUsage::PRICING_VERIFIED_ON)
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
