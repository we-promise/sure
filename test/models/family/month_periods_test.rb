require "test_helper"

class Family::MonthPeriodsTest < ActiveSupport::TestCase
  include SalaryAnchorsTestHelper

  setup do
    @family = families(:dylan_family)
    travel_to Date.new(2026, 11, 11)
    @salary = declare_salary(@family)
    anchor_months_to(@family, @salary)
  end

  teardown do
    travel_back
  end

  test "each month runs from one salary to the day before the next" do
    land_salaries(Date.new(2026, 8, 27), Date.new(2026, 9, 29), Date.new(2026, 10, 27))

    assert_bounds Date.new(2026, 8, 27), Date.new(2026, 9, 28), Date.new(2026, 9, 10)
    assert_bounds Date.new(2026, 9, 29), Date.new(2026, 10, 26), Date.new(2026, 9, 29)
    assert_bounds Date.new(2026, 9, 29), Date.new(2026, 10, 26), Date.new(2026, 10, 26)
  end

  test "an early or late salary moves the boundary to the day it landed" do
    land_salaries(Date.new(2026, 8, 27), Date.new(2026, 9, 24), Date.new(2026, 10, 30))

    assert_bounds Date.new(2026, 8, 27), Date.new(2026, 9, 23), Date.new(2026, 9, 1)
    assert_bounds Date.new(2026, 9, 24), Date.new(2026, 10, 29), Date.new(2026, 10, 28)
  end

  test "the open month is projected one month past the latest salary" do
    land_salaries(Date.new(2026, 9, 29), Date.new(2026, 10, 27))

    assert_bounds Date.new(2026, 10, 27), Date.new(2026, 11, 26), Date.new(2026, 11, 11)
    assert_bounds Date.new(2026, 12, 27), Date.new(2027, 1, 26), Date.new(2027, 1, 2)
  end

  test "projections count from the salary so a 31st does not drift after February" do
    land_salaries(Date.new(2027, 1, 31))

    assert_bounds Date.new(2027, 2, 28), Date.new(2027, 3, 30), Date.new(2027, 3, 1)
    assert_bounds Date.new(2027, 3, 31), Date.new(2027, 4, 29), Date.new(2027, 4, 1)
  end

  test "dates before the first salary fall back to fixed-day months, clipped at that salary" do
    land_salaries(Date.new(2026, 8, 27))

    assert_bounds Date.new(2026, 7, 1), Date.new(2026, 7, 31), Date.new(2026, 7, 15)
    assert_bounds Date.new(2026, 8, 1), Date.new(2026, 8, 26), Date.new(2026, 8, 10)

    @family.update!(month_start_day: 15)
    assert_bounds Date.new(2026, 8, 15), Date.new(2026, 8, 26), Date.new(2026, 8, 20)
  end

  test "a second inflow inside the minimum gap does not start a new month" do
    land_salaries(Date.new(2026, 9, 29), Date.new(2026, 10, 10), Date.new(2026, 10, 27))

    assert_equal [ Date.new(2026, 9, 29), Date.new(2026, 10, 27) ], @family.month_periods.anchors
    assert_equal [ Date.new(2026, 9, 29), Date.new(2026, 10, 10), Date.new(2026, 10, 27) ],
      Family::MonthPeriods.new(@family, min_gap_days: 5).anchors
  end

  test "only confirmed matches anchor the month" do
    land_salaries(Date.new(2026, 9, 29))
    land_salary(@salary, Date.new(2026, 10, 27), state: "suggested")

    assert_equal [ Date.new(2026, 9, 29) ], @family.month_periods.anchors
  end

  test "inflows matched to another income series do not move the month" do
    land_salaries(Date.new(2026, 9, 29), Date.new(2026, 10, 27))
    side_gig = declare_salary(@family, name: "FREELANCE CLIENT", amount: 400)
    land_salary(side_gig, Date.new(2026, 11, 5))

    assert_bounds Date.new(2026, 10, 27), Date.new(2026, 11, 26), Date.new(2026, 11, 11)
  end

  test "a paused or deleted salary falls back to fixed-day months" do
    land_salaries(Date.new(2026, 9, 29), Date.new(2026, 10, 27))

    @salary.update!(status: "paused")
    assert_bounds Date.new(2026, 11, 1), Date.new(2026, 11, 30), Date.new(2026, 11, 11)
    assert_not @family.uses_custom_month_start?
    assert @family.month_start_series_missing?

    @salary.update!(status: "active")
    @salary.destroy!
    @family.reload
    assert_nil @family.month_start_recurring_transaction_id
    assert_bounds Date.new(2026, 11, 1), Date.new(2026, 11, 30), Date.new(2026, 11, 11)
  end

  test "first_start_in_month finds the earlier of two starts in one calendar month" do
    land_salaries(Date.new(2026, 8, 1), Date.new(2026, 8, 29), Date.new(2026, 10, 1))
    periods = @family.month_periods

    assert_equal Date.new(2026, 8, 1), periods.first_start_in_month(Date.new(2026, 8, 20))
    assert_nil periods.first_start_in_month(Date.new(2026, 9, 1))
    assert_equal Date.new(2026, 10, 1), periods.first_start_in_month(Date.new(2026, 10, 15))
  end

  private
    def land_salaries(*dates)
      dates.each { |date| land_salary(@salary, date) }
    end

    def assert_bounds(expected_start, expected_end, date)
      assert_equal [ expected_start, expected_end ], @family.month_periods.bounds_for(date), "bounds for #{date}"
    end
end
