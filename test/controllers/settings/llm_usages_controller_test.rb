require "test_helper"

class Settings::LlmUsagesControllerTest < ActionDispatch::IntegrationTest
  test "admin can view family LLM usage" do
    sign_in users(:family_admin)
    get settings_llm_usage_path
    assert_response :success
    assert_includes response.body, I18n.l(LlmUsage::PRICING_VERIFIED_ON)
  end

  test "usage shows one row per call, which opens to show its requests" do
    family = users(:family_admin).family
    call_id = SecureRandom.uuid
    attributes = { provider: "openai", model: "gpt-4.1", operation: "bill_setup", prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 }
    family.llm_usages.create!(**attributes, call_id:, status: "failed", metadata: { "error" => "Service unavailable" }, created_at: 2.minutes.ago)
    family.llm_usages.create!(**attributes, call_id:, status: "succeeded", created_at: 1.minute.ago)

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_response :success
    assert_select "tbody tr", 1
    assert_select "tbody tr details", 1
    assert_includes response.body, I18n.t("settings.llm_usages.requests.summary", count: 2)
    assert_includes response.body, "Service unavailable"
    assert_includes response.body, I18n.t("settings.llm_usages.show.total_calls")
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
