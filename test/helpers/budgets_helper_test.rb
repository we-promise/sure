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

  test "keeps group when only subcategory is over budget" do
    parent = Category.create!(
      name: "Helper Group Parent #{SecureRandom.hex(4)}",
      family: @family,
      color: "#22c55e",
      lucide_icon: "utensils"
    )

    child = Category.create!(
      name: "Helper Group Child #{SecureRandom.hex(4)}",
      parent: parent,
      family: @family
    )

    BudgetCategory.create!(
      budget: @budget,
      category: parent,
      budgeted_spending: 300,
      currency: "USD"
    )

    BudgetCategory.create!(
      budget: @budget,
      category: child,
      budgeted_spending: 50,
      currency: "USD"
    )

    Entry.create!(
      account: accounts(:depository),
      entryable: Transaction.create!(category: child),
      date: Date.current,
      name: "Helper Child Over Budget",
      amount: 100,
      currency: "USD"
    )

    state = budget_categories_view_state(Budget.find(@budget.id))
    group = state[:over_budget_groups].find { |g| g.budget_category.category_id == parent.id }

    assert group.present?
    refute group.budget_category.any_over_budget?
    assert_equal [ child.id ], group.budget_subcategories.map(&:category_id)
    assert group.budget_subcategories.first.any_over_budget?
  end

  test "budget has over budget when uncategorized spending exceeds its allocation" do
    family = Family.create!(name: "Helper Budget Repro", currency: "USD")
    account = Account.create!(
      family: family,
      accountable: Depository.new,
      name: "Checking",
      status: "active",
      currency: "USD",
      balance: 0
    )

    category = Category.create!(
      name: "Helper Groceries #{SecureRandom.hex(4)}",
      family: family,
      color: "#407706",
      lucide_icon: "shopping-bag"
    )

    budget = Budget.create!(
      family: family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD",
      budgeted_spending: 100
    )

    BudgetCategory.create!(
      budget: budget,
      category: category,
      budgeted_spending: 100,
      currency: "USD"
    )

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Helper Uncategorized Over Budget",
      amount: 125,
      currency: "USD"
    )

    assert budget_has_over_budget?(Budget.find(budget.id))
  end
end
