require "test_helper"

class Rule::ActionExecutor::SetTransactionCategoryTest < ActiveSupport::TestCase
  setup do
    @rule = rules(:one)
    @executor = Rule::ActionExecutor::SetTransactionCategory.new(@rule)
  end

  test "options groups subcategories immediately after their parent" do
    options = @executor.options

    parent_index = options.index { |_label, id| id == categories(:food_and_drink).id }
    child_index = options.index { |_label, id| id == categories(:subcategory).id }

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "options does not indent subcategory labels, so value_display doesn't show the arrow" do
    action = Rule::Action.new(
      rule: @rule,
      action_type: "set_transaction_category",
      value: categories(:subcategory).id
    )

    assert_equal categories(:subcategory).name, action.value_display
  end
end
