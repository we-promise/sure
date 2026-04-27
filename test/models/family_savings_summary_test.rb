require "test_helper"

class FamilySavingsSummaryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)
  end

  test "savings_summary_for returns SavingsSummary value object" do
    summary = @family.savings_summary_for(@budget)
    assert_kind_of Family::SavingsSummary, summary
    assert_respond_to summary, :surplus
    assert_respond_to summary, :allocated
    assert_respond_to summary, :available
    assert_respond_to summary, :active_goals
    assert_respond_to summary, :currency
  end

  test "summary lists only active goals" do
    summary = @family.savings_summary_for(@budget)
    assert(summary.active_goals.all?(&:active?), "expected only active goals")
    assert_not_includes summary.active_goals, savings_goals(:paid_off_car)
  end

  test "summary allocated equals sum of monthly targets of active goals" do
    summary = @family.savings_summary_for(@budget)
    expected = @family.savings_goals.where(state: "active").sum { |g| g.monthly_target_amount || 0 }
    assert_equal expected, summary.allocated
  end

  test "summary surplus reflects budget monthly_surplus" do
    summary = @family.savings_summary_for(@budget)
    assert_equal @budget.monthly_surplus, summary.surplus
  end

  test "summary available is surplus minus allocated, never negative" do
    summary = @family.savings_summary_for(@budget)
    assert_equal [ summary.surplus - summary.allocated, 0 ].max, summary.available
    assert_operator summary.available, :>=, 0
  end

  test "summary is memoized per budget" do
    first = @family.savings_summary_for(@budget)
    second = @family.savings_summary_for(@budget)
    assert_same first, second
  end

  test "money helpers wrap with budget currency" do
    summary = @family.savings_summary_for(@budget)
    assert_kind_of Money, summary.surplus_money
    assert_kind_of Money, summary.allocated_money
    assert_kind_of Money, summary.available_money
  end
end
