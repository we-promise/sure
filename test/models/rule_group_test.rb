require "test_helper"

class RuleGroupTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @group = @family.rule_groups.create!(name: "Food")
  end

  test "names are unique per family and stripped" do
    assert_not @family.rule_groups.new(name: " Food ").valid?
    assert families(:dylan_family).rule_groups.new(name: "Food").valid?
  end

  test "rejects text the database cannot store" do
    assert_not @family.rule_groups.new(name: "Fo\0od").valid?
    assert_not @family.rule_groups.new(name: "\xFF".dup.force_encoding("UTF-8")).valid?
  end

  test "switch_rules switches every rule of the group and only those" do
    first = create_rule(active: false)
    second = create_rule(active: false)
    outside = @family.rules.create!(resource_type: "transaction", active: false,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    assert_empty @group.switch_rules(true)

    assert first.reload.active?
    assert second.reload.active?
    assert_not outside.reload.active?

    assert_empty @group.switch_rules(false)
    assert_not first.reload.active?
  end

  test "switch_rules reports rules kept off because the email baseline timed out" do
    rule = @family.rules.create!(resource_type: "transaction", active: false, rule_group: @group,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: "amzn") ],
      actions: [ Rule::Action.new(action_type: "send_email_notification") ])
    plain = create_rule(active: false)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_equal [ rule ], @group.switch_rules(true)
    assert_not rule.reload.active?
    assert plain.reload.active?
  end

  test "find_or_create_named! finds a group another request created meanwhile" do
    family = families(:empty)
    existing = family.rule_groups.create!(name: "Bills")
    # The lookup misses, as if the other request committed right after it.
    RuleGroup.stubs(:find_by).returns(nil)

    assert_no_difference "RuleGroup.count" do
      assert_equal existing, family.rule_groups.find_or_create_named!("Bills")
    end
  end

  private
    def create_rule(active:)
      @family.rules.create!(resource_type: "transaction", active: active, rule_group: @group,
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
end
