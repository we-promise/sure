require "test_helper"

class Assistant::Function::CreateRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateRule.new(@user)
    @category = categories(:food_and_drink)
  end

  test "saves the rule inactive and returns a preview" do
    create_transaction(name: "ZXQ Coffee Shop", amount: 4.5)
    create_transaction(name: "ZXQ Coffee Beans", amount: 25)

    result = nil
    assert_difference "@family.rules.count", 1 do
      result = @fn.call(
        "name" => "Coffee",
        "conditions" => [
          { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq coffee" },
          { "condition_type" => "transaction_amount", "operator" => "<", "value" => "10" }
        ],
        "actions" => [
          { "action_type" => "set_transaction_category", "value" => @category.id },
          { "action_type" => "set_transaction_tags", "value" => [ tags(:one).id, tags(:two).id ] }
        ]
      )
    end

    assert result[:success], result.inspect
    rule = @family.rules.find(result[:rule][:id])
    assert_not rule.active
    assert_equal "Coffee", rule.name
    assert_equal 2, rule.conditions.count
    assert_equal [ tags(:one).id, tags(:two).id ].sort, rule.actions.find_by(action_type: "set_transaction_tags").value.split(",").sort
    assert_equal 1, result[:preview][:match_count]
  end

  test "ignores an attempt to create an active rule" do
    result = @fn.call(
      "active" => true,
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    )

    assert result[:success]
    assert_not @family.rules.find(result[:rule][:id]).active
  end

  test "does not save an invalid rule" do
    assert_no_difference "Rule.count" do
      result = @fn.call(
        "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ],
        "actions" => [
          { "action_type" => "exclude_transaction" },
          { "action_type" => "exclude_transaction" }
        ]
      )

      assert_equal "invalid_rule", result[:error]
    end

    assert_no_difference "Rule.count" do
      assert_equal "invalid_rule", @fn.call("conditions" => [], "actions" => [])[:error]
    end
  end

  test "rejects AI-backed actions and ids from outside the family" do
    other_category = families(:empty).categories.create!(name: "Elsewhere", color: "#000000")

    result = @fn.call(
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq" } ],
      "actions" => [
        { "action_type" => "auto_detect_merchants" },
        { "action_type" => "set_transaction_category", "value" => other_category.id }
      ]
    )

    assert_equal "invalid_rule", result[:error]
    assert_equal 2, result[:problems].size
  end

  test "only accepts accounts the user can see" do
    member_fn = Assistant::Function::CreateRule.new(users(:family_member))
    params = {
      "conditions" => [ { "condition_type" => "transaction_account", "operator" => "=", "value" => accounts(:other_asset).id } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    }

    assert_equal "invalid_rule", member_fn.call(params)[:error]
    assert @fn.call(params)[:success]
  end
end
