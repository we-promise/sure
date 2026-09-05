require "test_helper"

class Family::AiPromptableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "every key has a built-in default and no override out of the box" do
    Family::AiPromptable::KEYS.each do |key|
      assert_nil @family.ai_prompt(key), "#{key} should start with no override"
      assert @family.ai_prompt_default(key).present?, "#{key} resolved no built-in default"
    end
  end

  # The riskiest part of this feature is a mistyped key at one of the four
  # provider resolution sites, which would silently keep serving the default.
  test "each provider override reaches its instructions method" do
    @family.update!(
      ai_prompt_categorizer_openai: "CAT OPENAI",
      ai_prompt_categorizer_anthropic: "CAT ANTHROPIC",
      ai_prompt_merchant_openai: "MERCHANT OPENAI",
      ai_prompt_merchant_anthropic: "MERCHANT ANTHROPIC"
    )

    assert_equal "CAT OPENAI",
      Provider::Openai::AutoCategorizer.new(nil, family: @family).instructions
    assert_equal "CAT ANTHROPIC",
      Provider::Anthropic::AutoCategorizer.new(nil, model: "", family: @family).instructions
    assert_equal "MERCHANT OPENAI",
      Provider::Openai::AutoMerchantDetector.new(nil, model: "", transactions: [], user_merchants: [], family: @family).instructions
    assert_equal "MERCHANT ANTHROPIC",
      Provider::Anthropic::AutoMerchantDetector.new(nil, model: "", transactions: [], user_merchants: [], family: @family).instructions
  end

  test "an override wins over the custom_provider variant, not just the detailed one" do
    @family.update!(ai_prompt_categorizer_openai: "CAT OPENAI")

    categorizer = Provider::Openai::AutoCategorizer.new(nil, custom_provider: true, family: @family)

    assert_equal "CAT OPENAI", categorizer.instructions
  end

  test "a blank value resets the key rather than storing an empty prompt" do
    @family.update!(ai_prompt_chat_system: "Be terse.")
    assert_equal "Be terse.", @family.ai_prompt(:chat_system)

    @family.update!(ai_prompt_chat_system: "")

    assert_nil @family.ai_prompt(:chat_system)
    assert_not @family.reload.ai_prompt_overrides.key?("chat_system")
  end

  test "rejects an override longer than the cap with formatted error message" do
    @family.ai_prompt_chat_system = "x" * (Family::AiPromptable::MAX_LENGTH + 1)

    assert_not @family.valid?
    assert_includes @family.errors.attribute_names, :ai_prompt_chat_system
    assert_equal "Chat system prompt is too long (maximum is 20,000 characters)",
      @family.errors.full_messages_for(:ai_prompt_chat_system).first
  end
end
