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

  test "previous_budget_param returns param when date is valid" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_not_nil budget.previous_budget_param
  end

  test "find_or_bootstrap uses custom month boundaries when family has custom month_start_day" do
    @family.update!(month_start_day: 15)

    budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 2, 20))

    assert_equal Date.new(2026, 2, 15), budget.start_date
    assert_equal Date.new(2026, 3, 14), budget.end_date
  end

  test "find_or_bootstrap uses calendar month boundaries when month_start_day is 1" do
    @family.update!(month_start_day: 1)

    budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 2, 20))

    assert_equal Date.new(2026, 2, 1), budget.start_date
    assert_equal Date.new(2026, 2, 28), budget.end_date
  end

  test "current? returns true for custom month budget when dates match" do
    @family.update!(month_start_day: 15)

    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)

    assert budget.current?
  end

  test "name shows date range for custom month budgets" do
    @family.update!(month_start_day: 15)

    budget = Budget.create!(
      family: @family,
      start_date: Date.new(2026, 2, 15),
      end_date: Date.new(2026, 3, 14),
      currency: "USD"
    )

    assert_equal "Feb 15 - Mar 14, 2026", budget.name
  end

  test "name shows month year for calendar month budgets" do
    @family.update!(month_start_day: 1)

    budget = Budget.create!(
      family: @family,
      start_date: Date.new(2026, 2, 1),
      end_date: Date.new(2026, 2, 28),
      currency: "USD"
    )

    assert_equal "February 2026", budget.name
  end

  test "param_to_date handles ISO format" do
    date = Budget.param_to_date("2026-02-15", family: @family)
    assert_equal Date.new(2026, 2, 15), date
  end

  test "param_to_date handles legacy format with calendar month" do
    @family.update!(month_start_day: 1)
    date = Budget.param_to_date("feb-2026", family: @family)
    assert_equal Date.new(2026, 2, 1), date
  end

  test "param_to_date handles legacy format with custom month start" do
    @family.update!(month_start_day: 15)
    date = Budget.param_to_date("feb-2026", family: @family)
    assert_equal Date.new(2026, 2, 15), date
  end
end
