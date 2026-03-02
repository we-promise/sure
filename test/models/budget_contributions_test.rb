require "test_helper"

class BudgetContributionsTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "goal_contributions_for_month aggregates auto and manual contributions correctly" do
    # Create a clean budget for this test
    start_date = Date.current.beginning_of_month
    budget = Budget.create!(
      family: @family,
      start_date: start_date,
      end_date: start_date.end_of_month,
      currency: "USD"
    )

    # Create a saving goal
    goal = SavingGoal.create!(
      family: @family,
      name: "Test Goal",
      target_amount: 1000,
      currency: "USD",
      status: :active
    )

    # Add AUTO contribution
    SavingContribution.create!(
      saving_goal: goal,
      amount: 100,
      month: start_date,
      currency: "USD",
      source: :auto
    )

    # Add MANUAL contribution
    SavingContribution.create!(
      saving_goal: goal,
      amount: 50,
      month: start_date,
      currency: "USD",
      source: :manual
    )

    # Add INITIAL_BALANCE contribution (should be IGNORED)
    SavingContribution.create!(
      saving_goal: goal,
      amount: 200,
      month: start_date,
      currency: "USD",
      source: :initial_balance
    )

    # Fetch contributions via the method under test
    contributions = budget.goal_contributions_for_month(goal)

    # Verify count
    assert_equal 2, contributions.count

    # Verify sum
    assert_equal 150, contributions.sum(:amount)
  end
end
