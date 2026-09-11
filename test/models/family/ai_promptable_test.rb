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

  # One override key feeds both OpenAI variants, so the editor has to pre-fill
  # the one this deployment sends. Getting it backwards hands a small local
  # model a prompt written for GPT-4, with no error to trace it back to.
  test "openai defaults follow the deployment's provider mode" do
    Family::AiPromptable.stubs(:custom_openai_provider?).returns(true)

    assert_includes @family.ai_prompt_default(:categorizer_openai), '{"categorizations":'
    assert_includes @family.ai_prompt_default(:merchant_openai), '{"merchants":'

    Family::AiPromptable.stubs(:custom_openai_provider?).returns(false)

    assert_not_includes @family.ai_prompt_default(:categorizer_openai), '{"categorizations":'
    assert_not_includes @family.ai_prompt_default(:merchant_openai), '{"merchants":'
  end

  # Advisory only. It has to stay quiet for the pre-filled default (which now
  # carries the key on custom providers), or admins learn to ignore it.
  test "flags only an openai override that dropped the wrapper key" do
    Family::AiPromptable.stubs(:custom_openai_provider?).returns(true)

    assert_not @family.ai_prompt_format_risk?(:categorizer_openai), "no override should not warn"

    @family.update!(ai_prompt_categorizer_openai: "Categorise them. Be conservative.")
    assert @family.ai_prompt_format_risk?(:categorizer_openai)

    @family.update!(ai_prompt_categorizer_openai: 'Be conservative. {"categorizations": [...]}')
    assert_not @family.ai_prompt_format_risk?(:categorizer_openai)

    # Anthropic's wrapper key comes from the tool schema, so wording can't drop it.
    @family.update!(ai_prompt_categorizer_anthropic: "No wrapper key in here.")
    assert_not @family.ai_prompt_format_risk?(:categorizer_anthropic)
  end

  test "does not flag a dropped wrapper key on native openai" do
    Family::AiPromptable.stubs(:custom_openai_provider?).returns(false)
    @family.update!(ai_prompt_categorizer_openai: "Categorise them. Be conservative.")

    assert_not @family.ai_prompt_format_risk?(:categorizer_openai)
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

  test "rejects non-hash ai_prompt_overrides" do
    @family.ai_prompt_overrides = "not a hash"

    assert_not @family.valid?
    assert_includes @family.errors.attribute_names, :ai_prompt_overrides
  end

  test "rejects unknown keys in ai_prompt_overrides" do
    @family.ai_prompt_overrides = { "unsupported_prompt" => "Custom text" }

    assert_not @family.valid?
    assert_includes @family.errors.attribute_names, :ai_prompt_overrides
  end

  test "rejects non-string values in ai_prompt_overrides" do
    @family.ai_prompt_overrides = { "chat_system" => 123 }

    assert_not @family.valid?
    assert_includes @family.errors.attribute_names, :ai_prompt_chat_system
  end

  test "rejects null bytes in ai_prompt_overrides" do
    @family.ai_prompt_chat_system = "instructions\u0000with null byte"

    assert_not @family.valid?
    assert_includes @family.errors.attribute_names, :ai_prompt_chat_system
  end
end
