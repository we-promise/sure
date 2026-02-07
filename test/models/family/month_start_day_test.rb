require "test_helper"

class Family::MonthStartDayTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "month_start_day defaults to 1" do
    assert_equal 1, @family.month_start_day
  end

  test "validates month_start_day is between 1 and 28" do
    @family.month_start_day = 0
    assert_not @family.valid?

    @family.month_start_day = 29
    assert_not @family.valid?

    @family.month_start_day = 15
    assert @family.valid?
  end

  test "uses_custom_month_start? returns false when month_start_day is 1" do
    @family.month_start_day = 1
    assert_not @family.uses_custom_month_start?
  end

  test "uses_custom_month_start? returns true when month_start_day is not 1" do
    @family.month_start_day = 25
    assert @family.uses_custom_month_start?
  end

  test "custom_month_start_for returns correct start date when day is after month_start_day" do
    @family.month_start_day = 15

    travel_to Date.new(2026, 1, 20) do
      result = @family.custom_month_start_for(Date.current)
      assert_equal Date.new(2026, 1, 15), result
    end
  end

  test "custom_month_start_for returns correct start date when day is before month_start_day" do
    @family.month_start_day = 15

    travel_to Date.new(2026, 1, 10) do
      result = @family.custom_month_start_for(Date.current)
      assert_equal Date.new(2025, 12, 15), result
    end
  end

  test "custom_month_end_for returns one day before next custom month start" do
    @family.month_start_day = 15

    travel_to Date.new(2026, 1, 20) do
      result = @family.custom_month_end_for(Date.current)
      assert_equal Date.new(2026, 2, 14), result
    end
  end

  test "current_custom_month_period returns correct period" do
    @family.month_start_day = 25

    travel_to Date.new(2026, 1, 27) do
      period = @family.current_custom_month_period

      assert_equal Date.new(2026, 1, 25), period.start_date
      assert_equal Date.new(2026, 2, 24), period.end_date
    end
  end
end
