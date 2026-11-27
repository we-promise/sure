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

  # Just after midnight in Madrid the host clock (UTC here) is still on the
  # previous day. The default range must end on the family's today, or the
  # calls made since midnight drop out of the page.
  test "the default range ends on the family's today, not the host's" do
    family = users(:family_admin).family
    family.update!(timezone: "Europe/Madrid")

    with_env_overrides("TZ" => "UTC") do
      travel_to Time.utc(2026, 11, 15, 23, 30) do # 00:30 on November 16 in Madrid
        family.llm_usages.create!(provider: "openai", model: "gpt-4.1", operation: "bill_setup", prompt_tokens: 100,
                                  completion_tokens: 10, total_tokens: 110, status: "succeeded", created_at: 10.minutes.ago)

        sign_in users(:family_admin)
        get settings_llm_usage_path
      end
    end

    assert_response :success
    assert_select "tbody tr", 1
  end

  test "a cancelled call of one request says so" do
    users(:family_admin).family.llm_usages.create!(provider: "openai", model: "gpt-4.1", operation: "bill_setup", prompt_tokens: 100,
                                                   completion_tokens: 0, total_tokens: 100, status: "cancelled")

    sign_in users(:family_admin)
    get settings_llm_usage_path

    assert_select "tbody tr td", text: /#{I18n.t("settings.llm_usages.show.cancelled")}/
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
