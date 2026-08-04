require "test_helper"

class BudgetDonutViewTest < ActionView::TestCase
  test "renders hover content for uncategorized donut segment" do
    family = Family.create!(name: "Budget Donut View Repro", currency: "USD")
    account = Account.create!(
      family: family,
      accountable: Depository.new,
      name: "Checking",
      status: "active",
      currency: "USD",
      balance: 0
    )

    category = Category.create!(
      name: "Groceries #{SecureRandom.hex(4)}",
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
      name: "Uncategorized hover spending",
      amount: 125,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    uncategorized = budget.uncategorized_budget_category

    html = render(partial: "budgets/budget_donut", locals: { budget: budget })

    assert_includes html, "segment_#{uncategorized.id}"
    assert_includes html, uncategorized.category.display_name
  end
end
