require "test_helper"

class Assistant::Function::PreviewRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::PreviewRule.new(@user)
    @category = categories(:food_and_drink)
  end

  def definition(conditions: nil, actions: nil)
    {
      "conditions" => conditions || [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq coffee" } ],
      "actions" => actions || [ { "action_type" => "set_transaction_category", "value" => @category.id } ]
    }
  end

  test "previews an unsaved definition without saving or changing anything" do
    entry = create_transaction(name: "ZXQ Coffee Shop", amount: 4.5)
    create_transaction(name: "Groceries")

    assert_no_difference [ "Rule.count", "Rule::Condition.count", "Rule::Action.count" ] do
      result = @fn.call(definition)

      assert result[:success], result.inspect
      assert_equal 1, result[:preview][:match_count]
      assert_equal [ entry.entryable.id ], result[:preview][:sample].map { |t| t[:id] }
      assert_equal @category.name_with_parent, result[:preview][:actions].first[:value_name]
    end

    assert_nil entry.entryable.reload.category_id
  end

  test "previews a saved rule" do
    create_transaction(name: "ZXQ Coffee Shop")
    rule = @family.rules.create!(resource_type: "transaction", **rule_attributes)

    result = @fn.call("rule_id" => rule.id)

    assert result[:success]
    assert_equal 1, result[:preview][:match_count]
  end

  test "respects effective_date and compound or conditions" do
    create_transaction(name: "ZXQ Coffee Shop", date: 10.days.ago.to_date)
    create_transaction(name: "ZXQ Tea House", date: 2.days.ago.to_date)
    create_transaction(name: "ZXQ Bakery", date: 2.days.ago.to_date)

    params = definition(conditions: [
      { "condition_type" => "compound", "operator" => "or", "sub_conditions" => [
        { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq coffee" },
        { "condition_type" => "transaction_name", "operator" => "like", "value" => "zxq tea" }
      ] }
    ])

    assert_equal 2, @fn.call(params)[:preview][:match_count]
    assert_equal 1, @fn.call(params.merge("effective_date" => 5.days.ago.to_date.iso8601))[:preview][:match_count]
  end

  test "rejects invalid definitions with every problem listed" do
    result = @fn.call(definition(
      conditions: [
        { "condition_type" => "transaction_amount", "operator" => "like", "value" => "5" },
        { "condition_type" => "transaction_category", "operator" => "=", "value" => SecureRandom.uuid }
      ],
      actions: [ { "action_type" => "auto_categorize" } ]
    ))

    assert_not result[:success]
    assert_equal "invalid_rule", result[:error]
    assert_equal 3, result[:problems].size
  end

  test "rejects nested compound conditions and non-numeric amounts" do
    nested = @fn.call(definition(conditions: [
      { "condition_type" => "compound", "operator" => "and", "sub_conditions" => [
        { "condition_type" => "compound", "operator" => "or", "sub_conditions" => [] }
      ] }
    ]))
    assert_match "cannot be nested", nested[:problems].first

    amount = @fn.call(definition(conditions: [ { "condition_type" => "transaction_amount", "operator" => ">", "value" => "abc" } ]))
    assert_match "must be a number", amount[:problems].first
  end

  test "rejects operators a filter lists but cannot apply" do
    result = @fn.call(definition(conditions: [ { "condition_type" => "transaction_tag", "operator" => "!=", "value" => tags(:one).id } ]))

    assert_equal "invalid_rule", result[:error]
  end

  test "requires exactly one of rule_id or a definition" do
    assert_equal "invalid_arguments", @fn.call({})[:error]

    rule = @family.rules.create!(resource_type: "transaction", **rule_attributes)
    assert_equal "invalid_arguments", @fn.call(definition.merge("rule_id" => rule.id))[:error]
  end

  test "counts the whole family but samples only accounts the user can see" do
    create_transaction(name: "ZXQ Coffee Shop", account: accounts(:other_asset))
    visible = create_transaction(name: "ZXQ Coffee Bar", account: accounts(:depository))

    result = Assistant::Function::PreviewRule.new(users(:family_member)).call(definition)

    assert_equal 2, result[:preview][:match_count]
    assert_equal 1, result[:preview][:visible_match_count]
    assert_equal [ visible.entryable.id ], result[:preview][:sample].map { |t| t[:id] }
  end

  private
    def rule_attributes
      {
        conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
        actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
      }
    end
end
