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

  test "summary handles a family with no active goals" do
    @family.savings_goals.update_all(state: "archived")
    fresh = Family.find(@family.id) # fresh instance to clear @savings_summary_cache memo
    summary = fresh.savings_summary_for(@budget)
    assert_empty summary.active_goals
    assert_equal 0, summary.allocated
    assert_equal summary.surplus, summary.available
  end

  test "memoization is keyed by budget id, not shared across budgets" do
    other_budget = @family.budgets.create!(
      start_date: @budget.start_date.next_month.beginning_of_month,
      end_date: @budget.start_date.next_month.end_of_month,
      currency: @budget.currency
    )
    summary_a = @family.savings_summary_for(@budget)
    summary_b = @family.savings_summary_for(other_budget)
    assert_not_same summary_a, summary_b, "different budgets must yield distinct memo entries"
    summary_a_again = @family.savings_summary_for(@budget)
    assert_same summary_a, summary_a_again
  end

  test "summary excludes goals in other currencies" do
    eur_account = @family.accounts.create!(
      name: "Euro Pot", balance: 0, currency: "EUR",
      accountable: Depository.new
    )
    eur_goal = @family.savings_goals.create!(
      account: eur_account,
      name: "Tour de France",
      target_amount: 3_000,
      target_date: 6.months.from_now.to_date,
      state: "active"
    )
    summary = @family.savings_summary_for(@budget) # USD budget
    assert_not_includes summary.active_goals, eur_goal
    assert summary.active_goals.all? { |g| g.currency == @budget.currency }
  end

  test "money helpers wrap with budget currency" do
    summary = @family.savings_summary_for(@budget)
    assert_kind_of Money, summary.surplus_money
    assert_kind_of Money, summary.allocated_money
    assert_kind_of Money, summary.available_money
  end
end
