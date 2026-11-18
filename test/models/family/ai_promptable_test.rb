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

  # One override per feature reaches whichever prompt the route sends, on every provider.
  test "each feature's override reaches the prompt its route sends" do
    @family.update!(ai_prompt_categorize_transactions: "CATEGORIZE", ai_prompt_detect_merchants: "MERCHANTS")

    assert_equal "CATEGORIZE", instructions(:categorize, "categorize_transactions", :compatible)
    assert_equal "CATEGORIZE", instructions(:categorize, "categorize_transactions_simple", :compatible)
    assert_equal "CATEGORIZE", instructions(:categorize, "categorize_transactions_anthropic", :anthropic)
    assert_equal "MERCHANTS", instructions(:detect_merchants, "detect_merchants_simple", :compatible)
    assert_equal "MERCHANTS", instructions(:detect_merchants, "detect_merchants_anthropic", :anthropic)
  end

  # The editor pre-fills the prompt this install sends. Getting it wrong hands a small local
  # model a prompt written for GPT-4, with no error to trace it back to.
  test "a generation key's default is the prompt the family's route sends" do
    with_ai_route_prompts("categorize_transactions_simple", "detect_merchants_simple") do
      assert_includes @family.ai_prompt_default(:categorize_transactions), '{"categorizations":'
      assert_includes @family.ai_prompt_default(:detect_merchants), '{"merchants":'
    end
    with_ai_route_prompts("categorize_transactions", "detect_merchants") do
      assert_not_includes @family.ai_prompt_default(:categorize_transactions), '{"categorizations":'
      assert_not_includes @family.ai_prompt_default(:detect_merchants), '{"merchants":'
    end
    use_no_ai
    assert_equal RubyLLM.render_prompt("categorize_transactions/instructions"), @family.ai_prompt_default(:categorize_transactions)
  end

  # Advisory only. It has to stay quiet for the pre-filled default, and on prompts that get their
  # shape from the schema, or admins learn to ignore it.
  test "flags only an override of the simplified prompt that dropped the wrapper key" do
    with_ai_route_prompts("categorize_transactions_simple", "detect_merchants_simple") do
      assert_not @family.ai_prompt_format_risk?(:categorize_transactions), "no override should not warn"

      @family.update!(ai_prompt_categorize_transactions: "Categorise them. Be conservative.")
      assert @family.ai_prompt_format_risk?(:categorize_transactions)

      @family.update!(ai_prompt_categorize_transactions: 'Be conservative. {"categorizations": [...]}')
      assert_not @family.ai_prompt_format_risk?(:categorize_transactions)
    end

    with_ai_route_prompts("categorize_transactions", "detect_merchants") do
      @family.update!(ai_prompt_categorize_transactions: "Categorise them. Be conservative.")
      assert_not @family.ai_prompt_format_risk?(:categorize_transactions)
    end
  end

  test "the key collapse's dropped overrides are listed until cleared" do
    DebugLogEntry.create!(category: Family::AiPromptable::DROPPED_CATEGORY, level: "warn", message: "dropped", source: "test",
                          family: @family, metadata: { key: "categorize_transactions", text: "My Anthropic prompt" })

    assert_equal [ { key: "categorize_transactions", text: "My Anthropic prompt" } ], @family.dropped_ai_prompt_overrides

    @family.clear_dropped_ai_prompt_overrides
    assert_empty @family.dropped_ai_prompt_overrides
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

  private
    def with_ai_route_prompts(categorize, detect, &block)
      config = AiTestHelper.test_config
      routes = { categorize:, detect_merchants: detect }.to_h do |feature, prompt|
        [ feature, [ config.routes_for(feature).first.with(prompt:) ] ]
      end
      Ai::Config.with(Ai::Config.new(endpoints: config.endpoints, models: config.models, routes: config.routes.merge(routes)), &block)
    end

    def instructions(feature, prompt, protocol)
      endpoint = Ai::Config::Endpoint.new(name: protocol, protocol:, api_key: "test-key")
      route = Ai::Route.new(feature:, model: Ai::Config::Model.new(endpoint:, name: "m"), prompt:)
      locals = { transactions: [], categories: [], merchants: [] }
      Ai::Prompt.for(feature, default: prompt, route:, family: @family, locale: nil, locals:).instructions
    end
end
