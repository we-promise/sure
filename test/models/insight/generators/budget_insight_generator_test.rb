require "test_helper"

class Insight::Generators::BudgetInsightGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @category = Category.create!(name: "Insight Groceries", family: @family, color: "#e74c3c")
  end

  test "default plan keeps the legacy month-only dedup key" do
    make_over_budget!(budgets(:one))

    insights = Insight::Generators::BudgetInsightGenerator.new(@family).generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "budget_at_risk", insight.insight_type
    assert_equal "budget_at_risk:#{Date.current.strftime('%Y-%m')}", insight.dedup_key
    assert_equal budgets(:one).to_param, insight.metadata[:budget_param]
  end

  test "sibling plans get their own insight with a plan-scoped dedup key and named title" do
    make_over_budget!(budgets(:one))

    plan = budget_plans(:dylan_personal)
    sibling = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)
    make_over_budget!(sibling)

    insights = Insight::Generators::BudgetInsightGenerator.new(@family).generate

    assert_equal 2, insights.size
    sibling_insight = insights.find { |i| i.metadata[:budget_param] == sibling.to_param }
    assert_not_nil sibling_insight
    assert_equal "budget_at_risk:#{plan.id}:#{Date.current.strftime('%Y-%m')}", sibling_insight.dedup_key
    assert_match plan.name, sibling_insight.title
  end

  test "uninitialized sibling budgets produce no insight" do
    make_over_budget!(budgets(:one))
    Budget.find_or_bootstrap(@family, start_date: Date.current, plan: budget_plans(:dylan_personal))

    insights = Insight::Generators::BudgetInsightGenerator.new(@family).generate

    assert_equal 1, insights.size
  end

  private
    # Gives the budget an over-limit category: $100 budgeted, $200 spent.
    def make_over_budget!(budget)
      budget.update!(budgeted_spending: budget.budgeted_spending || 1000)
      budget.sync_budget_categories
      budget.budget_categories.find_by!(category: @category).update!(budgeted_spending: 100)

      Entry.create!(
        account: accounts(:depository),
        entryable: Transaction.create!(category: @category),
        date: budget.start_date,
        name: "Overspend for #{budget.id}",
        amount: 200,
        currency: "USD"
      )
    end
end
