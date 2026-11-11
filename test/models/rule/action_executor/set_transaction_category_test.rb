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

  test "a plan-owned purchase keeps its category and reports no change" do
    family = @rule.family
    user = family.users.first
    card = family.accounts.create!(
      name: "Rule Plan Card", accountable: CreditCard.new, balance: 0,
      currency: "USD", owner: user, status: "active"
    )
    purchase = card.entries.create!(
      date: Date.current, name: "Laptop", amount: 1200, currency: "USD",
      entryable: Transaction.new(kind: "standard", category: family.categories.first)
    )
    RecurringTransaction::InstallmentPlan.new(
      family: family, user: user, entry: purchase,
      interest_rate: 0, term_months: 12
    ).call
    original_category = purchase.reload.transaction.category
    replacement = family.categories.where.not(id: original_category.id).first

    [ false, true ].each do |ignore_locks|
      count = @executor.execute(
        Transaction.where(id: purchase.entryable_id),
        value: replacement.id,
        ignore_attribute_locks: ignore_locks
      )

      assert_equal 0, count
      assert_equal original_category, purchase.reload.transaction.category
    end
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
