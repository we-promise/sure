require "test_helper"

class Budget::RolloverCalculatorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @parent = @family.categories.create!(name: "Annual expenses", color: "#6172F3")
    @fund = @family.categories.create!(name: "Annual service", parent: @parent, color: "#6172F3")
    @account = @family.accounts.create!(
      accountable: Depository.new, name: "Fund checking", currency: "USD",
      balance: 10_000, status: "active", owner: users(:josh)
    )
  end

  test "an independent fund accumulates three contributions and pays its bill" do
    first = funded_month(3, contribution: 1_200)
    second = funded_month(2, contribution: 120)
    third = funded_month(1, contribution: 120)
    recompute!

    assert_equal 1_200, fund_for(first).available_to_spend
    assert_equal 1_320, fund_for(second).available_to_spend
    assert_equal 1_440, fund_for(third).available_to_spend

    spend(1_000, third)
    recompute!

    assert_equal 440, fund_for(third).available_to_spend
    assert_equal 120, third.allocated_spending
    assert_equal 0, third.available_to_allocate
  end

  test "a zero contribution month preserves an independent fund and its outgoing carry" do
    funded_month(3, contribution: 1_200)
    second = funded_month(2, contribution: 0)
    third = funded_month(1, contribution: 120)
    recompute!

    second_fund = fund_for(second)
    assert_not second_fund.inherits_parent_budget?
    assert_equal 1_200, second_fund.rolled_over_amount
    assert_equal 1_200, second_fund.available_to_spend
    assert_equal 0, second_fund.display_budgeted_spending
    assert_equal 1_320, fund_for(third).available_to_spend

    spend(1_000, third)
    recompute!

    assert_equal 320, fund_for(third).available_to_spend
  end

  test "an enabled fund with an unset allocation is independent before carry is materialized" do
    budget = funded_month(1, contribution: 0)
    fund = fund_for(budget)
    fund.budgeted_spending = nil

    assert_equal 0, fund[:rolled_over_amount]
    assert_not fund.inherits_parent_budget?
  end

  test "disabling a zero contribution fund clears stale carry and stops the chain" do
    funded_month(3, contribution: 1_200)
    second = funded_month(2, contribution: 0)
    third = funded_month(1, contribution: 120)
    # Materialized carry may remain until the next recompute.
    fund_for(second).update!(rollover_enabled: false, rolled_over_amount: 1_200)
    second_fund = fund_for(second)
    assert second_fund.inherits_parent_budget?
    assert_equal 0, second_fund.rolled_over_amount
    assert_equal 0, second.reload.total_rolled_over

    recompute!

    assert_equal 0, fund_for(second)[:rolled_over_amount]
    assert_equal 0, fund_for(third).rolled_over_amount
    assert_equal 120, fund_for(third).available_to_spend
  end

  test "zero allocation independence preserves parent and shared child balances" do
    funded_month(2, contribution: 800, reserve: 200)
    second = funded_month(1, contribution: 80, reserve: 20)
    shared = @family.categories.create!(name: "Shared expenses", parent: @parent, color: "#6172F3")
    second.sync_budget_categories
    spend(220, second)
    recompute!
    second = Budget.find(second.id)

    assert_equal 800, fund_for(second).rolled_over_amount
    assert_equal 200, second.budget_categories.find_by!(category: @parent).rolled_over_amount
    assert_equal 1_000, second.total_rolled_over
    assert_equal 100, second.budgeted_spending
    assert_equal 100, second.allocated_spending
    assert_equal 0, second.available_to_allocate
    assert_equal 880, second.budget_categories.find_by!(category: @parent).available_to_spend
    assert_equal 220, second.budget_categories.find_by!(category: shared).available_to_spend
  end


  test "zero contribution funds stay in their household and personal chains" do
    @family.update!(personal_budgets: true)
    josh = users(:josh)
    ann = users(:ann)
    funded_month(2, contribution: 1_200)
    funded_month(2, contribution: 400, user: josh)
    funded_month(2, contribution: 700, user: ann)
    household = funded_month(1, contribution: 0)
    personal = funded_month(1, contribution: 0, user: josh)
    other = funded_month(1, contribution: 0, user: ann)
    spend(100, personal)
    [ nil, josh, ann ].each { |user| recompute!(user: user) }

    assert_equal 1_200, fund_for(household).rolled_over_amount
    assert_equal 400, fund_for(personal).rolled_over_amount
    assert_equal 700, fund_for(other).rolled_over_amount
  end

  test "recomputing another family does not rewrite this family's carry" do
    funded_month(2, contribution: 1_200)
    second = funded_month(1, contribution: 0)
    recompute!

    Budget::RolloverCalculator.new(family: families(:dylan_family), user: nil).recompute!

    assert_equal 1_200, fund_for(second).rolled_over_amount
  end

  test "a zero contribution fund does not carry an amount across currencies" do
    funded_month(2, contribution: 1_200)
    @family.update!(currency: "EUR")
    second = funded_month(1, contribution: 0)
    recompute!

    assert_equal "EUR", second.currency
    assert_equal 0, fund_for(second).rolled_over_amount
  end

  private
    def funded_month(months_ago, contribution:, reserve: 0, user: nil)
      budget = Budget.find_or_bootstrap(@family, start_date: months_ago.months.ago, user: user)
      budget.update!(budgeted_spending: contribution + reserve, expected_income: 2_000)
      budget.budget_categories.find_by!(category: @parent).update!(budgeted_spending: reserve, rollover_enabled: true)
      fund = fund_for(budget)
      fund.update!(rollover_enabled: true)
      fund.update_budgeted_spending!(contribution)
      budget
    end

    def fund_for(budget)
      BudgetCategory.find_by!(budget_id: budget.id, category: @fund)
    end

    def spend(amount, budget)
      create_transaction(account: @account, date: budget.start_date, amount: amount, category: @fund)
    end

    def recompute!(user: nil)
      Budget::RolloverCalculator.new(family: @family, user: user).recompute!
    end
end
