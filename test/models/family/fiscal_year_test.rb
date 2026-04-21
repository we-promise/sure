require "test_helper"

class Family::FiscalYearTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "fiscal_year_start_month and fiscal_year_start_day default to 1" do
    assert_equal 1, @family.fiscal_year_start_month
    assert_equal 1, @family.fiscal_year_start_day
  end

  test "validates fiscal_year_start_month is between 1 and 12" do
    @family.fiscal_year_start_month = 0
    assert_not @family.valid?

    @family.fiscal_year_start_month = 13
    assert_not @family.valid?

    @family.fiscal_year_start_month = 3
    assert @family.valid?
  end

  test "validates fiscal_year_start_day is between 1 and 28" do
    @family.fiscal_year_start_day = 0
    assert_not @family.valid?

    @family.fiscal_year_start_day = 29
    assert_not @family.valid?

    @family.fiscal_year_start_day = 1
    assert @family.valid?
  end

  test "uses_fiscal_year? returns false when start is January 1" do
    @family.fiscal_year_start_month = 1
    @family.fiscal_year_start_day = 1
    assert_not @family.uses_fiscal_year?
  end

  test "uses_fiscal_year? returns true when start month is not January" do
    @family.fiscal_year_start_month = 3
    assert @family.uses_fiscal_year?
  end

  test "uses_fiscal_year? returns true when start day is not 1" do
    @family.fiscal_year_start_day = 15
    assert @family.uses_fiscal_year?
  end

  test "current_fiscal_year_start returns this year's start when today is on or after it" do
    @family.fiscal_year_start_month = 3
    @family.fiscal_year_start_day = 1

    travel_to Date.new(2026, 4, 21) do
      assert_equal Date.new(2026, 3, 1), @family.current_fiscal_year_start
    end
  end

  test "current_fiscal_year_start rolls back one year when today is before the start" do
    @family.fiscal_year_start_month = 7
    @family.fiscal_year_start_day = 1

    travel_to Date.new(2026, 4, 21) do
      assert_equal Date.new(2025, 7, 1), @family.current_fiscal_year_start
    end
  end

  test "current_fiscal_year_start returns Jan 1 of current year for default settings" do
    travel_to Date.new(2026, 4, 21) do
      assert_equal Date.new(2026, 1, 1), @family.current_fiscal_year_start
    end
  end
end
