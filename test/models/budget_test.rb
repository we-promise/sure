require "test_helper"

class BudgetTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "budget_date_valid? allows going back 2 years even without entries" do
    two_years_ago = 2.years.ago.beginning_of_month
    assert Budget.budget_date_valid?(two_years_ago, family: @family)
  end

  test "budget_date_valid? allows going back to earliest entry date if more than 2 years ago" do
    # Create an entry 3 years ago
    old_account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Old Account",
      status: "active",
      currency: "USD",
      balance: 1000
    )

    old_entry = Entry.create!(
      account: old_account,
      entryable: Transaction.new(category: categories(:income)),
      date: 3.years.ago,
      name: "Old Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should allow going back to the old entry date
    assert Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? does not allow dates before earliest entry or 2 years ago" do
    # Create an entry 1 year ago
    account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Test Account",
      status: "active",
      currency: "USD",
      balance: 500
    )

    Entry.create!(
      account: account,
      entryable: Transaction.new(category: categories(:income)),
      date: 1.year.ago,
      name: "Recent Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should not allow going back more than 2 years
    refute Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? does not allow future dates beyond current month" do
    refute Budget.budget_date_valid?(2.months.from_now, family: @family)
  end

  test "previous_budget_param returns nil when date is too old" do
    # Create a budget at the oldest allowed date
    two_years_ago = 2.years.ago.beginning_of_month
    budget = Budget.create!(
      family: @family,
      start_date: two_years_ago,
      end_date: two_years_ago.end_of_month,
      currency: "USD"
    )

    assert_nil budget.previous_budget_param
  end

  test "actual_spending nets refunds against expenses in same category" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)

    healthcare = Category.create!(
      name: "Healthcare #{Time.now.to_f}",
      family: family,
      color: "#e74c3c",
      classification: "expense"
    )

    budget.sync_budget_categories
    budget_category = budget.budget_categories.find_by(category: healthcare)
    budget_category.update!(budgeted_spending: 200)

    account = accounts(:depository)

    # Create a $500 expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: healthcare),
      date: Date.current,
      name: "Doctor visit",
      amount: 500,
      currency: "USD"
    )

    # Create a $200 refund (negative amount = income classification in the SQL)
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: healthcare),
      date: Date.current,
      name: "Insurance reimbursement",
      amount: -200,
      currency: "USD"
    )

    # Clear memoized values
    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    # Budget category should show net spending: $500 - $200 = $300
    assert_equal 300, budget.budget_category_actual_spending(
      budget.budget_categories.find_by(category: healthcare)
    )
  end

  test "budget_category_actual_spending does not go below zero" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)

    category = Category.create!(
      name: "Returns Only #{Time.now.to_f}",
      family: family,
      color: "#3498db",
      classification: "expense"
    )

    budget.sync_budget_categories
    budget_category = budget.budget_categories.find_by(category: category)
    budget_category.update!(budgeted_spending: 100)

    account = accounts(:depository)

    # Only a refund, no expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Full refund",
      amount: -50,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    assert_equal 0, budget.budget_category_actual_spending(
      budget.budget_categories.find_by(category: category)
    )
  end

  test "actual_spending subtracts uncategorized refunds" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)
    account = accounts(:depository)

    # Create an uncategorized expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Uncategorized purchase",
      amount: 400,
      currency: "USD"
    )

    # Create an uncategorized refund
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Uncategorized refund",
      amount: -150,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    # The uncategorized refund should reduce overall actual_spending
    # Other fixtures may contribute spending, so check that the net
    # uncategorized amount (400 - 150 = 250) is reflected by comparing
    # with and without the refund rather than asserting an exact total.
    spending_with_refund = budget.actual_spending

    # Remove the refund and check spending increases
    Entry.find_by(name: "Uncategorized refund").destroy!
    budget = Budget.find(budget.id)
    spending_without_refund = budget.actual_spending

    assert_equal 150, spending_without_refund - spending_with_refund
  end

  test "most_recent_initialized_budget returns latest initialized budget before this one" do
    family = families(:dylan_family)

    # Create an older initialized budget (2 months ago)
    older_budget = Budget.create!(
      family: family,
      start_date: 2.months.ago.beginning_of_month,
      end_date: 2.months.ago.end_of_month,
      budgeted_spending: 3000,
      expected_income: 5000,
      currency: "USD"
    )

    # Create a middle uninitialized budget (1 month ago)
    Budget.create!(
      family: family,
      start_date: 1.month.ago.beginning_of_month,
      end_date: 1.month.ago.end_of_month,
      currency: "USD"
    )

    current_budget = Budget.find_or_bootstrap(family, start_date: Date.current)

    assert_equal older_budget, current_budget.most_recent_initialized_budget
  end

  test "most_recent_initialized_budget returns nil when none exist" do
    family = families(:empty)
    budget = Budget.create!(
      family: family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_nil budget.most_recent_initialized_budget
  end

  test "copy_from copies budgeted_spending expected_income and matching category budgets" do
    family = families(:dylan_family)

    # Use past months to avoid fixture conflict (fixture :one is at Date.current for dylan_family)
    source_budget = Budget.find_or_bootstrap(family, start_date: 2.months.ago)
    source_budget.update!(budgeted_spending: 4000, expected_income: 6000)
    source_bc = source_budget.budget_categories.find_by(category: categories(:food_and_drink))
    source_bc.update!(budgeted_spending: 500)

    target_budget = Budget.find_or_bootstrap(family, start_date: 1.month.ago)
    assert_nil target_budget.budgeted_spending

    target_budget.copy_from!(source_budget)
    target_budget.reload

    assert_equal 4000, target_budget.budgeted_spending
    assert_equal 6000, target_budget.expected_income

    target_bc = target_budget.budget_categories.find_by(category: categories(:food_and_drink))
    assert_equal 500, target_bc.budgeted_spending
  end

  test "copy_from skips categories that dont exist in target" do
    family = families(:dylan_family)

    source_budget = Budget.find_or_bootstrap(family, start_date: 2.months.ago)
    source_budget.update!(budgeted_spending: 4000, expected_income: 6000)

    # Create a category only in the source budget
    temp_category = Category.create!(name: "Temp #{Time.now.to_f}", family: family, color: "#aaa", classification: "expense")
    source_budget.budget_categories.create!(category: temp_category, budgeted_spending: 100, currency: "USD")

    target_budget = Budget.find_or_bootstrap(family, start_date: 1.month.ago)

    # Should not raise even though target doesn't have the temp category
    assert_nothing_raised { target_budget.copy_from!(source_budget) }
    assert_equal 4000, target_budget.reload.budgeted_spending
  end

  test "copy_from leaves new categories at zero" do
    family = families(:dylan_family)

    source_budget = Budget.find_or_bootstrap(family, start_date: 2.months.ago)
    source_budget.update!(budgeted_spending: 4000, expected_income: 6000)

    target_budget = Budget.find_or_bootstrap(family, start_date: 1.month.ago)

    # Add a new category only to the target
    new_category = Category.create!(name: "New #{Time.now.to_f}", family: family, color: "#bbb", classification: "expense")
    target_budget.budget_categories.create!(category: new_category, budgeted_spending: 0, currency: "USD")

    target_budget.copy_from!(source_budget)

    new_bc = target_budget.budget_categories.find_by(category: new_category)
    assert_equal 0, new_bc.budgeted_spending
  end

  test "previous_budget_param returns param when date is valid" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_not_nil budget.previous_budget_param
  end

  test "uncategorized budget category actual spending reflects uncategorized transactions" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)
    account = accounts(:depository)

    # Create an uncategorized expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Uncategorized lunch",
      amount: 75,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    uncategorized_bc = budget.uncategorized_budget_category
    spending = budget.budget_category_actual_spending(uncategorized_bc)

    # Must be > 0 — the nil-key collision between Uncategorized and
    # Other Investments synthetic categories previously caused this to return 0
    assert spending >= 75, "Uncategorized actual spending should include the $75 transaction, got #{spending}"
  end
end
