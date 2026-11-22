require "test_helper"

class RulesHelperTest < ActionView::TestCase
  include RulesHelper

  setup do
    @rule = families(:dylan_family).rules.build(resource_type: "transaction")
  end

  test "an action whose type is no longer supported gets a fallback label instead of raising" do
    action = @rule.actions.build(action_type: "no_longer_supported", value: "x")

    assert_equal I18n.t("rules.unsupported_action"), rule_action_label(action)
  end

  test "a supported action keeps its own label" do
    action = @rule.actions.build(action_type: "exclude_transaction")

    assert_equal action.executor.label, rule_action_label(action)
  end
end
