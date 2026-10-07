require "test_helper"

class Insight::Generators::BudgetInsightGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)
    @category = @family.categories.create!(name: "Budget Insight Cat", color: "#101010", lucide_icon: "circle")
  end

  # 95 of 100 spent would be "near the limit", but the spend sits on
  # `connected`, private to family_admin. The shared feed must not report it.
  test "spending on an account private to one member does not put the budget at risk" do
    budget_category(@budget)
    create_transaction(category: @category, amount: 95, account: accounts(:connected), date: Date.current)

    assert_not_includes generated_types, "budget_at_risk"
  end

  test "spending on a shared account still puts the budget at risk" do
    budget_category(@budget)
    create_transaction(category: @category, amount: 95, date: Date.current)

    assert_includes generated_types, "budget_at_risk"
  end

  # With every account private, nothing is counted, so "on track" would only
  # mean that no shared spending exists.
  test "no budget insight when no account is visible to every member" do
    AccountShare.where(account: @family.accounts).delete_all
    budget_category(@budget)

    travel_to @budget.end_date do
      assert_empty generated_types
    end
  end

  # A personal budget is visible to its owner and whoever they shared it with,
  # never to the whole family, so it must not reach the shared feed.
  test "a personal budget is not reported" do
    @budget.destroy!
    personal = @family.budgets.create!(
      user: users(:family_admin), start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month, budgeted_spending: 100, expected_income: 0, currency: "USD"
    )
    budget_category(personal)
    create_transaction(category: @category, amount: 95, date: Date.current)

    assert_empty generated_types
  end

  private
    def budget_category(budget)
      budget.budget_categories.create!(category: @category, budgeted_spending: 100, currency: "USD")
    end

    def generated_types
      Insight::Generators::BudgetInsightGenerator.new(@family).generate.map(&:insight_type)
    end
end
