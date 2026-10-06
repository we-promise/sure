require "test_helper"

class Assistant::Function::GetRuleOptionsTest < ActiveSupport::TestCase
  setup do
    @fn = Assistant::Function::GetRuleOptions.new(users(:family_admin))
  end

  test "describes conditions and actions without AI-backed actions" do
    result = @fn.call

    assert result[:success]
    condition_types = result[:conditions].map { |c| c[:condition_type] }
    assert_includes condition_types, "transaction_name"
    assert_includes condition_types, "compound"

    amount = result[:conditions].find { |c| c[:condition_type] == "transaction_amount" }
    assert_includes amount[:operators].map { |o| o[:value] }, "="

    tag = result[:conditions].find { |c| c[:condition_type] == "transaction_tag" }
    assert_equal %w[= is_null], tag[:operators].map { |o| o[:value] }

    action_types = result[:actions].map { |a| a[:action_type] }
    assert_includes action_types, "set_transaction_category"
    assert_not_includes action_types, "auto_categorize"
    assert_not_includes action_types, "auto_detect_merchants"
  end

  test "inlines fixed value lists and points id values at their tools" do
    result = @fn.call

    type = result[:conditions].find { |c| c[:condition_type] == "transaction_type" }
    assert_equal %w[income expense transfer], type[:values]

    category = result[:actions].find { |a| a[:action_type] == "set_transaction_category" }
    assert_match "get_categories", category[:values]
  end
end
