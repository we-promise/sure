require "test_helper"

class Rule::Registry::TransactionResourceTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "auto categorization is available when Jev is the only categorization provider" do
    rule = build_rule(action_type: "auto_categorize")
    @family.stubs(:resolved_categorization_provider).returns(Provider::Jev.allocate)
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    keys = rule.registry.action_executors.map(&:key)

    assert_includes keys, "auto_categorize"
    assert_not_includes keys, "auto_detect_merchants"
    assert_instance_of Rule::ActionExecutor::AutoCategorize, rule.actions.first.executor
  end

  test "existing auto categorization actions stay displayable when no provider is configured" do
    rule = build_rule(action_type: "auto_categorize")
    @family.stubs(:resolved_categorization_provider).returns(nil)
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    keys = rule.registry.action_executors.map(&:key)

    assert_includes keys, "auto_categorize"
    assert_instance_of Rule::ActionExecutor::AutoCategorize, rule.actions.first.executor
  end

  test "new auto categorization actions are hidden when no provider is configured" do
    rule = build_rule(action_type: "exclude_transaction")
    @family.stubs(:resolved_categorization_provider).returns(nil)
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    keys = rule.registry.action_executors.map(&:key)

    assert_not_includes keys, "auto_categorize"
  end

  test "auto merchant detection is available when an LLM provider is configured" do
    rule = build_rule(action_type: "exclude_transaction")
    @family.stubs(:resolved_categorization_provider).returns(nil)
    Provider::Registry.stubs(:preferred_llm_provider).returns(Provider::Anthropic.allocate)

    keys = rule.registry.action_executors.map(&:key)

    assert_not_includes keys, "auto_categorize"
    assert_includes keys, "auto_detect_merchants"
  end

  private
    def build_rule(action_type:)
      @family.rules.create!(
        name: "Transaction registry test",
        resource_type: "transaction",
        effective_date: 1.day.ago.to_date,
        actions: [ Rule::Action.new(action_type: action_type) ]
      )
    end
end
