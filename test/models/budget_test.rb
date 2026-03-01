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

  test "budget_date_valid? allows future dates up to 2 years ahead" do
    travel_to Date.current.beginning_of_month do
      assert Budget.budget_date_valid?(Date.current.beginning_of_month + 1.month, family: @family)
      assert Budget.budget_date_valid?(Date.current.beginning_of_month + 2.years, family: @family)
    end
  end

  test "budget_date_valid? does not allow future dates beyond 2 years ahead" do
    travel_to Date.current.beginning_of_month do
      refute Budget.budget_date_valid?(Date.current.beginning_of_month + 2.years + 1.month, family: @family)
    end
  end

  test "budget_date_valid? for custom month start allows dates up to 2 years ahead" do
    @family.update!(month_start_day: 15)

    travel_to Date.current.beginning_of_month do
      cap_start = @family.current_custom_month_period.start_date + 2.years
      assert Budget.budget_date_valid?(cap_start, family: @family)
    end
  end

  test "budget_date_valid? for custom month start does not allow dates beyond 2 years ahead" do
    @family.update!(month_start_day: 15)

    travel_to Date.current.beginning_of_month do
      beyond_cap = @family.current_custom_month_period.start_date + 2.years + 1.month
      refute Budget.budget_date_valid?(beyond_cap, family: @family)
    end
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

  test "next_budget_param returns next month when current month budget is selected" do
    travel_to Date.current.beginning_of_month do
      budget = Budget.create!(
        family: @family,
        start_date: Date.current.beginning_of_month,
        end_date: Date.current.end_of_month,
        currency: "USD"
      )

      assert_equal Budget.date_to_param(Date.current.beginning_of_month + 1.month), budget.next_budget_param
    end
  end

  test "next_budget_param returns nil at future cap" do
    travel_to Date.current.beginning_of_month do
      cap_start = Date.current.beginning_of_month + 2.years
      budget = Budget.create!(
        family: @family,
        start_date: cap_start,
        end_date: cap_start.end_of_month,
        currency: "USD"
      )

      assert_nil budget.next_budget_param
    end
  end

  test "next_budget_param returns nil at future cap for custom month start" do
    @family.update!(month_start_day: 15)

    travel_to Date.current.beginning_of_month do
      cap_start = @family.current_custom_month_period.start_date + 2.years
      budget = Budget.create!(
        family: @family,
        start_date: cap_start,
        end_date: cap_start + 1.month - 1.day,
        currency: "USD"
      )

      assert_nil budget.next_budget_param
    end
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

  test "previous_budget_param returns param when date is valid" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_not_nil budget.previous_budget_param
  end
end
