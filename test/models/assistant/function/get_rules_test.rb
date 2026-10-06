require "test_helper"

class Assistant::Function::GetRulesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetRules.new(@user)
    @category = categories(:food_and_drink)

    @rule = @family.rules.create!(
      name: "Coffee",
      resource_type: "transaction",
      active: true,
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
  end

  test "lists rules with ids resolved to names" do
    result = @fn.call

    assert result[:success]
    rule = result[:rules].find { |r| r[:id] == @rule.id }
    assert_equal "Coffee", rule[:name]
    assert rule[:active]
    assert_equal({ condition_type: "transaction_name", operator: "like", value: "zxq coffee" }, rule[:conditions].first)
    assert_equal @category.name_with_parent, rule[:actions].first[:value_name]
    assert_nil rule[:last_run]
  end

  test "filters by active" do
    inactive = @family.rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "other" } ],
      actions_attributes: [ { action_type: "exclude_transaction" } ]
    )

    ids = @fn.call("active" => false)[:rules].map { |r| r[:id] }
    assert_includes ids, inactive.id
    assert_not_includes ids, @rule.id
  end

  test "single rule includes match count and last run" do
    create_transaction(name: "ZXQ Coffee Shop")
    RuleRun.create!(rule: @rule, rule_name: @rule.name, execution_type: "manual", status: "success",
                    transactions_queued: 1, transactions_processed: 1, transactions_modified: 1, executed_at: Time.current)

    result = @fn.call("rule_id" => @rule.id)

    assert result[:success]
    assert_equal 1, result[:rule][:match_count]
    assert_equal "success", result[:rule][:last_run][:status]
  end

  test "rules of another family are not found" do
    other = families(:empty).rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "x" } ],
      actions_attributes: [ { action_type: "exclude_transaction" } ]
    )

    assert_equal "not_found", @fn.call("rule_id" => other.id)[:error]
    assert_not_includes @fn.call[:rules].map { |r| r[:id] }, other.id
  end
end
