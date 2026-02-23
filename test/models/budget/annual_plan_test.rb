require "test_helper"

class Budget::AnnualPlanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @plan = Budget::AnnualPlan.new(@family, year: Date.current.year)
  end

  test "savings_rate returns 0 when annual_income is zero" do
    @plan.stubs(:annual_income).returns(0)
    @plan.stubs(:total_annual_expenses_excluding_savings).returns(500)

    assert_equal 0, @plan.savings_rate
  end

  test "savings_rate computes correct percentage" do
    @plan.stubs(:annual_income).returns(10000)
    @plan.stubs(:total_annual_expenses_excluding_savings).returns(7000)

    # savings_rate = (10000 - 7000) / 10000 * 100 = 30.0
    assert_in_delta 30.0, @plan.savings_rate, 0.1
  end

  test "projected_annual_savings returns 0 when no months elapsed" do
    @plan.stubs(:months_elapsed).returns(0)

    assert_equal 0, @plan.projected_annual_savings
  end

  test "projected_annual_savings extrapolates from YTD pace" do
    @plan.stubs(:months_elapsed).returns(6)
    @plan.stubs(:annual_income).returns(30000)
    @plan.stubs(:total_annual_expenses_excluding_savings).returns(24000)

    # YTD savings = 30000 - 24000 = 6000
    # projected = 6000 / 6 * 12 = 12000
    assert_in_delta 12000.0, @plan.projected_annual_savings, 0.01
  end
end
