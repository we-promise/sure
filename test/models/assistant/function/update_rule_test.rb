require "test_helper"

class Assistant::Function::UpdateRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::UpdateRule.new(@user)
    @category = categories(:food_and_drink)

    @rule = @family.rules.create!(
      name: "Coffee",
      resource_type: "transaction",
      active: true,
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
  end

  test "renaming keeps an active rule active" do
    result = @fn.call("rule_id" => @rule.id, "name" => "Morning coffee")

    assert result[:success]
    @rule.reload
    assert_equal "Morning coffee", @rule.name
    assert @rule.active
  end

  test "replacing conditions deactivates the rule" do
    create_transaction(name: "ZXQ Tea House")

    result = @fn.call("rule_id" => @rule.id, "conditions" => [
      { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq tea" }
    ])

    assert result[:success], result.inspect
    @rule.reload
    assert_not @rule.active
    assert_equal [ "zxq tea" ], @rule.conditions.map(&:value)
    assert_equal 1, @rule.actions.count
    assert_equal 1, result[:preview][:match_count]
    assert_match "deactivated", result[:message]
  end

  test "replacing actions swaps the whole list" do
    result = @fn.call("rule_id" => @rule.id, "actions" => [ { "action_type" => "exclude_transaction" } ])

    assert result[:success]
    assert_equal [ "exclude_transaction" ], @rule.reload.actions.map(&:action_type)
  end

  test "an invalid update changes nothing" do
    result = @fn.call("rule_id" => @rule.id, "name" => "Changed", "actions" => [])

    assert_equal "invalid_rule", result[:error]
    @rule.reload
    assert_equal "Coffee", @rule.name
    assert @rule.active
    assert_equal 1, @rule.actions.count
  end

  test "can deactivate but not activate" do
    assert @fn.call("rule_id" => @rule.id, "active" => false)[:success]
    assert_not @rule.reload.active

    assert_equal "cannot_activate", @fn.call("rule_id" => @rule.id, "active" => true)[:error]
    assert_not @rule.reload.active
  end

  test "requires a change and a rule in the family" do
    assert_equal "no_changes", @fn.call("rule_id" => @rule.id)[:error]
    assert_equal "not_found", @fn.call("rule_id" => SecureRandom.uuid, "name" => "x")[:error]
  end

  test "another family's rule is not found and left untouched" do
    foreign = families(:empty).rules.create!(
      name: "Theirs",
      resource_type: "transaction",
      active: true,
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq" } ],
      actions_attributes: [ { action_type: "set_transaction_name", value: "x" } ]
    )

    assert_equal "not_found", @fn.call("rule_id" => foreign.id, "name" => "Mine now", "active" => false)[:error]
    foreign.reload
    assert_equal "Theirs", foreign.name
    assert foreign.active
  end

  test "an update returns a preview with a token for apply_rule" do
    create_transaction(name: "ZXQ Coffee Shop")

    result = @fn.call("rule_id" => @rule.id, "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ])

    assert result[:success], result.inspect
    assert result.dig(:preview, :preview_token).present?
  end
end
