require "test_helper"

class Transaction::RuleableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.rules.destroy_all
    @transaction = transactions(:one)
    @transaction.entry.update!(name: "AMZN Mktp UK")
    @category = categories(:food_and_drink)
    @transaction.update!(category: @category)
  end

  test "eligible when no rule sets the category" do
    assert @transaction.eligible_for_category_rule?
  end

  test "not eligible when an active rule for the category already matches this transaction" do
    create_category_rule(name_like: "AMZN")

    assert_not @transaction.eligible_for_category_rule?
  end

  test "eligible when the category's only rule does not match this transaction" do
    create_category_rule(name_like: "AMAZON.CO.UK")

    assert @transaction.eligible_for_category_rule?
  end

  test "eligible when the matching rule for the category is inactive" do
    create_category_rule(name_like: "AMZN", active: false)

    assert @transaction.eligible_for_category_rule?
  end

  test "ignores rules for other resource types instead of raising" do
    rule = create_category_rule(name_like: "AMZN")
    rule.update_column(:resource_type, "account")

    assert_nothing_raised { assert @transaction.eligible_for_category_rule? }
  end

  test "not eligible without a category" do
    @transaction.update!(category: nil)

    assert_not @transaction.eligible_for_category_rule?
  end

  private
    def create_category_rule(name_like:, active: true)
      rule = @family.rules.build(name: "Test rule", resource_type: "transaction", active: active)
      rule.conditions.build(condition_type: "transaction_name", operator: "like", value: name_like)
      rule.actions.build(action_type: "set_transaction_category", value: @category.id.to_s)
      rule.save!
      rule
    end
end
