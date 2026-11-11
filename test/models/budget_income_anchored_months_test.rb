require "test_helper"

class BudgetIncomeAnchoredMonthsTest < ActiveSupport::TestCase
  include SalaryAnchorsTestHelper

  setup do
    @family = families(:dylan_family)
    @family.budgets.destroy_all
    travel_to Date.new(2026, 11, 11)
    @salary = declare_salary(@family)
    anchor_months_to(@family, @salary)
  end

  teardown do
    travel_back
  end

  test "an early salary closes the open budget and moves the projected one onto it" do
    land_salaries(Date.new(2026, 9, 29), Date.new(2026, 10, 27))
    open_budget = bootstrap(Date.current)
    assert_equal [ Date.new(2026, 10, 27), Date.new(2026, 11, 26) ], dates_of(open_budget)

    projected = bootstrap(Date.new(2026, 11, 27))
    projected.update!(budgeted_spending: 1000)

    travel_to Date.new(2026, 11, 25)
    land_salary(@salary, Date.current)
    current = bootstrap(Date.current)

    assert_equal [ Date.new(2026, 10, 27), Date.new(2026, 11, 24) ], dates_of(open_budget.reload)
    assert_equal projected.id, current.id
    assert_equal [ Date.new(2026, 11, 25), Date.new(2026, 12, 24) ], dates_of(current)
    assert_equal 1000, current.budgeted_spending
  end

  test "a late salary is reconciled after the recurring pipeline runs" do
    land_salaries(Date.new(2026, 9, 29), Date.new(2026, 10, 27))
    open_budget = bootstrap(Date.current)

    travel_to Date.new(2026, 11, 27)
    projected = bootstrap(Date.current)
    assert_equal [ Date.new(2026, 11, 27), Date.new(2026, 12, 26) ], dates_of(projected)

    travel_to Date.new(2026, 11, 28)
    land_salary(@salary, Date.current)
    Budget.reconcile_income_periods_for!(@family)

    assert_equal [ Date.new(2026, 10, 27), Date.new(2026, 11, 27) ], dates_of(open_budget.reload)
    assert_equal [ Date.new(2026, 11, 28), Date.new(2026, 12, 27) ], dates_of(projected.reload)
  end

  test "budgets that ended before the previous salary keep their stored dates" do
    history = @family.budgets.create!(start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30), currency: "USD")
    land_salaries(Date.new(2026, 8, 27), Date.new(2026, 9, 29), Date.new(2026, 10, 27))

    Budget.reconcile_income_periods_for!(@family)

    assert_equal [ Date.new(2026, 9, 1), Date.new(2026, 9, 30) ], dates_of(history.reload)
  end

  test "previous and next step across irregular months and round-trip through the URL" do
    land_salaries(Date.new(2026, 8, 27), Date.new(2026, 9, 29), Date.new(2026, 10, 27))
    september = bootstrap(Date.new(2026, 10, 1))
    assert_equal [ Date.new(2026, 9, 29), Date.new(2026, 10, 26) ], dates_of(september)
    assert_equal "sep-2026", september.to_param

    previous_param = september.previous_budget_param
    next_param = september.next_budget_param

    # August holds two starts: the fixed-day fallback on the 1st and the
    # first salary on the 27th, which is addressed by its full date.
    assert_equal "2026-08-27", previous_param
    assert_equal "oct-2026", next_param

    previous = bootstrap(Budget.param_to_date(previous_param, family: @family))
    following = bootstrap(Budget.param_to_date(next_param, family: @family))
    assert_equal [ Date.new(2026, 8, 27), Date.new(2026, 9, 28) ], dates_of(previous)
    assert_equal [ Date.new(2026, 10, 27), Date.new(2026, 11, 26) ], dates_of(following)
    assert following.current?
  end

  test "a month slug resolves to the month starting in it, and today to the current month" do
    land_salaries(Date.new(2026, 8, 27), Date.new(2026, 9, 29), Date.new(2026, 10, 27))

    assert_equal Date.new(2026, 9, 29), Budget.param_to_date("sep-2026", family: @family)
    assert_equal "oct-2026", Budget.date_to_param(Date.current, family: @family)
  end

  test "switching back to fixed days reuses an overlapping budget instead of failing" do
    land_salaries(Date.new(2026, 9, 29), Date.new(2026, 10, 27), Date.new(2026, 11, 28))
    anchored = @family.budgets.create!(start_date: Date.new(2026, 10, 27), end_date: Date.new(2026, 11, 27), currency: "USD")

    @family.update!(month_start_mode: "fixed_day", month_start_day: 27)

    assert_equal anchored.id, bootstrap(Date.current).id
  end

  private
    def land_salaries(*dates)
      dates.each { |date| land_salary(@salary, date) }
    end

    def bootstrap(date)
      Budget.find_or_bootstrap(@family, start_date: date)
    end

    def dates_of(budget)
      [ budget.start_date, budget.end_date ]
    end
end
