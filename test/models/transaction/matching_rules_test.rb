require "test_helper"

class Transaction::MatchingRulesTest < ActiveSupport::TestCase
  setup do
    @transaction = transactions(:one)
    @family = @transaction.entry.account.family
    @family.rules.destroy_all
  end

  test "lists the rules whose conditions match, in run order" do
    lower = create_rule(name: "Lower", condition_value: "starbucks", category: categories(:income), position: 2)
    upper = create_rule(name: "Upper", condition_value: "star", category: categories(:income), position: 1)
    create_rule(name: "Other", condition_value: "netflix", category: categories(:income), position: 3)

    assert_equal [ upper, lower ], matching_rules.rules
  end

  test "includes switched-off rules that match" do
    off = create_rule(name: "Off", condition_value: "starbucks", category: categories(:income), active: false)

    assert_equal [ off ], matching_rules.rules
  end

  test "respects the rule's effective date" do
    create_rule(name: "Future", condition_value: "starbucks", category: categories(:income), effective_date: 1.year.from_now.to_date)

    assert_empty matching_rules.rules
  end

  test "matches regex conditions" do
    rule = create_rule(name: "Regex", condition_value: "^Star", operator: "matches_regex", category: categories(:income))

    assert_equal [ rule ], matching_rules.rules
  end

  test "flags active rules that set the same attribute to different values" do
    upper = create_rule(name: "Upper", condition_value: "starbucks", category: categories(:income), position: 1)
    lower = create_rule(name: "Lower", condition_value: "star", category: categories(:food_and_drink), position: 2)

    result = matching_rules

    assert_equal [ :category_id ], result.conflicts.keys
    assert_equal [ upper, lower ], result.conflicts[:category_id]
    assert_empty result.overridden_attributes(upper)
    assert_equal [ :category_id ], result.overridden_attributes(lower)
  end

  test "only rules setting another value than the winner are overridden" do
    create_rule(name: "First", condition_value: "starbucks", category: categories(:income), position: 1)
    same = create_rule(name: "Same", condition_value: "star", category: categories(:income), position: 2)
    different = create_rule(name: "Different", condition_value: "bucks", category: categories(:food_and_drink), position: 3)

    result = matching_rules

    assert_empty result.overridden_attributes(same)
    assert_equal [ :category_id ], result.overridden_attributes(different)
  end

  test "a regex that times out matches nothing and leaves the other rules listed" do
    create_rule(name: "Slow", condition_value: "^Star", operator: "matches_regex", category: categories(:income))
    plain = create_rule(name: "Plain", condition_value: "starbucks", category: categories(:income))

    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_equal [ plain ], matching_rules.rules
  end

  test "a rule whose condition cannot be built matches nothing and leaves the other rules listed" do
    broken = create_rule(name: "Broken", condition_value: "starbucks", category: categories(:income))
    broken.conditions.first.update_columns(operator: "no_such_operator")
    plain = create_rule(name: "Plain", condition_value: "starbucks", category: categories(:income))

    assert_equal [ plain ], matching_rules.rules
  end

  test "reports the attributes matching rules set that were set by hand" do
    create_rule(name: "Coffee", condition_value: "starbucks", category: categories(:income))
    @transaction.lock_attr!(:category_id)

    assert_equal [ :category_id ], matching_rules.locked_attributes
  end

  test "reports locks on attributes actions set without reserving them" do
    rule = @family.rules.build(name: "Bayes", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "starbucks")
    rule.actions.build(action_type: "bayes_categorize")
    rule.save!
    @transaction.lock_attr!(:category_id)

    result = matching_rules

    assert_equal [ :category_id ], result.locked_attributes
    assert_empty result.conflicts
  end

  test "an action whose type is no longer supported is skipped and the rule stays listed" do
    rule = create_rule(name: "Retired", condition_value: "starbucks", category: categories(:income))
    rule.actions.first.update_column(:action_type, "retired_action")
    plain = create_rule(name: "Plain", condition_value: "starbucks", category: categories(:food_and_drink))

    result = matching_rules

    assert_equal [ rule, plain ], result.rules
    assert_empty result.conflicts
    assert_empty result.locked_attributes
  end

  test "reads the name lock from the entry" do
    rule = @family.rules.build(name: "Rename", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "starbucks")
    rule.actions.build(action_type: "set_transaction_name", value: "Coffee")
    rule.save!

    assert_empty matching_rules.locked_attributes

    @transaction.entry.lock_attr!(:name)

    assert_equal [ :name ], matching_rules.locked_attributes
  end

  test "rules setting the same value do not conflict" do
    upper = create_rule(name: "Upper", condition_value: "starbucks", category: categories(:income), position: 1)
    create_rule(name: "Lower", condition_value: "star", category: categories(:income), position: 2)

    result = matching_rules

    assert_empty result.conflicts
    assert_empty result.overridden_attributes(upper)
  end

  test "switched-off rules take no part in conflicts" do
    create_rule(name: "On", condition_value: "starbucks", category: categories(:income), position: 1)
    off = create_rule(name: "Off", condition_value: "star", category: categories(:food_and_drink), position: 2, active: false)

    result = matching_rules

    assert_empty result.conflicts
    assert_empty result.overridden_attributes(off)
  end

  test "rules below a matching stop-processing rule are stopped and take no part in conflicts" do
    stopper = create_rule(name: "Stop", condition_value: "starbucks", category: categories(:income), position: 1)
    stopper.update!(stop_processing: true)
    below = create_rule(name: "Below", condition_value: "star", category: categories(:food_and_drink), position: 2)
    off = create_rule(name: "Off", condition_value: "bucks", category: categories(:food_and_drink), position: 3, active: false)

    result = matching_rules

    assert_nil result.stopped_by(stopper)
    assert_equal stopper, result.stopped_by(below)
    assert_nil result.stopped_by(off)
    assert_empty result.conflicts
  end

  test "additive actions such as tags never conflict" do
    2.times do |i|
      rule = @family.rules.build(name: "Tags #{i}", resource_type: "transaction", active: true)
      rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "starbucks")
      rule.actions.build(action_type: "set_transaction_tags", value: tags(i.zero? ? :one : :two).id)
      rule.save!
    end

    assert_equal 2, matching_rules.rules.size
    assert_empty matching_rules.conflicts
  end

  test "evaluates every rule in one query, whatever the number of rules" do
    10.times { |i| create_rule(name: "Rule #{i}", condition_value: "starbucks", category: categories(:income)) }
    5.times { |i| create_rule(name: "Miss #{i}", condition_value: "netflix", category: categories(:income)) }

    result = nil
    queries = capture_sql_queries { result = matching_rules.rules }

    assert_equal 10, result.size
    assert_equal 1, queries.count { |sql| sql.include?("UNION ALL") }
    assert_operator queries.size, :<=, 6, queries.join("\n")
  end

  test "no rules, no query for matches" do
    queries = capture_sql_queries { assert_empty matching_rules.rules }

    assert_equal 0, queries.count { |sql| sql.include?("UNION ALL") }
  end

  private
    def matching_rules
      Transaction::MatchingRules.new(@transaction, rules: @family.rules)
    end

    def create_rule(name:, condition_value:, category:, operator: "like", active: true, position: nil, effective_date: nil)
      rule = @family.rules.build(name: name, resource_type: "transaction", active: active, position: position, effective_date: effective_date)
      rule.conditions.build(condition_type: "transaction_name", operator: operator, value: condition_value)
      rule.actions.build(action_type: "set_transaction_category", value: category.id)
      rule.save!
      rule
    end
end
