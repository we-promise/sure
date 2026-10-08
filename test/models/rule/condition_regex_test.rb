require "test_helper"

# A matches_regex condition is validated when it is saved, so an unsafe pattern
# never reaches a rule that runs on every sync.
class Rule::ConditionRegexTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "a rule with a valid regex condition saves" do
    rule = build_rule(value: '^amzn\s+mktp')

    assert_difference -> { @family.rules.count }, 1 do
      assert rule.save, rule.errors.full_messages.to_sentence
    end
  end

  {
    "a back-reference" => [ '(a*)*\1c', :regex_backreference ],
    "an unbalanced group" => [ "(", :regex_invalid ],
    "a pattern Postgres calls too complex" => [ "^(a{1,255}){1,255}(b)", :regex_invalid ],
    "an over-long pattern" => [ "a" * 201, :regex_too_long ]
  }.each do |description, (pattern, kind)|
    test "a rule with #{description} is rejected and nothing is saved" do
      rule = build_rule(value: pattern)

      assert_no_difference [ -> { @family.rules.count }, -> { Rule::Condition.count } ] do
        assert_not rule.save
      end

      assert rule.conditions.first.errors.of_kind?(:value, kind), rule.conditions.first.errors.details.inspect
    end
  end

  test "the same pattern is accepted under the contains operator" do
    rule = build_rule(value: "(", operator: "like")

    assert rule.save, rule.errors.full_messages.to_sentence
  end

  test "a sub-condition inside a compound condition is validated too" do
    rule = @family.rules.build(resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    compound = rule.conditions.build(condition_type: "compound", operator: "or")
    compound.sub_conditions.build(condition_type: "transaction_name", operator: "matches_regex", value: "(")

    assert_no_difference -> { @family.rules.count } do
      assert_not rule.save
    end
  end

  test "the validation does not run for other operators" do
    Rule::SafeRegex.expects(:error_for).never

    assert build_rule(value: "(", operator: "like").save
  end

  test "an unchanged regex condition is not probed again when its rule is saved" do
    rule = build_rule(value: "^amzn")
    rule.save!

    Rule::SafeRegex.expects(:error_for).never
    rule.update!(active: true)

    Rule::SafeRegex.expects(:error_for).with("^changed").returns(nil).once
    rule.conditions.first.update!(value: "^changed")
  end

  private
    def build_rule(value:, operator: "matches_regex")
      @family.rules.build(
        resource_type: "transaction",
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: operator, value: value) ],
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
      )
    end
end
