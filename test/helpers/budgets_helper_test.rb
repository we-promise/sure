require "test_helper"

class BudgetsHelperTest < ActionView::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)

    @parent_category = Category.create!(
      name: "Helper Parent #{SecureRandom.hex(4)}",
      family: @family,
      color: "#4da568",
      lucide_icon: "utensils"
    )

    @child_category = Category.create!(
      name: "Helper Child #{SecureRandom.hex(4)}",
      parent: @parent_category,
      family: @family
    )

    @parent_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @parent_category,
      budgeted_spending: 200,
      currency: "USD"
    )

    @child_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @child_category,
      budgeted_spending: 0,
      currency: "USD"
    )
  end

  test "hides inheriting subcategory with no budget and no spending from on-track section" do
    state = budget_categories_view_state(@budget)
    group = state[:on_track_groups].find { |g| g.budget_category.id == @parent_budget_category.id }

    assert group.present?
    assert_empty group.budget_subcategories
  end

  test "shows inheriting subcategory in on-track section when it has spending" do
    Entry.create!(
      account: accounts(:depository),
      entryable: Transaction.create!(category: @child_category),
      date: Date.current,
      name: "Helper Child Spending",
      amount: 25,
      currency: "USD"
    )

    budget = Budget.find(@budget.id)
    state = budget_categories_view_state(budget)
    group = state[:on_track_groups].find { |g| g.budget_category.category_id == @parent_category.id }

    assert group.present?
    assert_includes group.budget_subcategories.map(&:category_id), @child_category.id
  end
end
