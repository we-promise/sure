require "test_helper"

class SavingGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @saving_goal = saving_goals(:emergency_fund)
    @family = @user.family
  end

  test "should get index" do
    get saving_goals_url
    assert_response :success
  end

  test "should get new" do
    get new_saving_goal_url
    assert_response :success
  end

  test "should create saving_goal" do
    assert_difference("SavingGoal.count") do
      post saving_goals_url, params: { saving_goal: { name: "New Goal", target_amount: 1000 } }
    end

    assert_redirected_to saving_goals_url
  end

  test "should show saving_goal" do
    get saving_goal_url(@saving_goal)
    assert_response :success
  end

  test "should get edit" do
    get edit_saving_goal_url(@saving_goal)
    assert_response :success
  end

  test "should update saving_goal" do
    patch saving_goal_url(@saving_goal), params: { saving_goal: { name: "Updated Name" } }
    assert_redirected_to saving_goals_url
  end

  test "should destroy saving_goal" do
    assert_difference("SavingGoal.count", -1) do
      delete saving_goal_url(@saving_goal)
    end

    assert_redirected_to saving_goals_url
  end

  test "should pause saving_goal" do
    post pause_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goal_url(@saving_goal)
    assert @saving_goal.reload.paused?
  end

  test "should resume saving_goal" do
    @saving_goal.pause!
    post resume_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goal_url(@saving_goal)
    assert @saving_goal.reload.active?
  end

  test "should complete saving_goal" do
    post complete_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goal_url(@saving_goal)
    assert @saving_goal.reload.completed?
  end

  test "should archive saving_goal" do
    post archive_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goals_url
    assert @saving_goal.reload.archived?
  end

  test "should create saving_goal with initial amount" do
    assert_difference([ "SavingGoal.count", "SavingContribution.count" ]) do
      post saving_goals_url, params: { saving_goal: { name: "Goal with Initial", target_amount: 1000, initial_amount: 500 } }
    end

    goal = SavingGoal.find_by!(name: "Goal with Initial")
    assert_equal "Goal with Initial", goal.name
    assert_equal 500, goal.current_amount
    assert_equal 1, goal.saving_contributions.count
    assert_equal 500, goal.saving_contributions.first.amount
    assert_equal Date.current.beginning_of_month, goal.saving_contributions.first.month

    assert_redirected_to saving_goals_url
  end

  test "should create initial contribution with correct source and verify budget impact" do
    # Create a budget for the current month
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    initial_allocated = budget.allocated_to_goals

    # Target date 4 months from now
    target_date = 4.months.from_now.to_date
    target_amount = 1000
    initial_amount = 200

    assert_difference([ "SavingGoal.count", "SavingContribution.count" ]) do
      post saving_goals_url, params: { saving_goal: {
        name: "Goal with Initial",
        target_amount: target_amount,
        initial_amount: initial_amount,
        target_date: target_date
      } }
    end

    goal = SavingGoal.find_by!(name: "Goal with Initial")
    contribution = goal.saving_contributions.first

    assert_equal "initial_balance", contribution.source
    assert_equal initial_amount, goal.current_amount

    # Verify budget allocated amount hasn't changed despite the new contribution
    assert_equal initial_allocated, budget.allocated_to_goals

    # Verify monthly_target calculation
    # Logic: (Target - Initial) / Months remaining
    # Months remaining calculation: (target_date - current_date) in months + 1
    # If target is 4 months from now, months_remaining is roughly 5 (including current month)
    months_remaining = goal.months_remaining
    expected_monthly = ((target_amount - initial_amount) / months_remaining.to_f).round(2)

    assert_equal expected_monthly, goal.monthly_target

    # Now verify a manual contribution DOES affect the budget
    manual_contribution = goal.saving_contributions.create!(
      amount: 100,
      currency: goal.currency,
      month: Date.current.beginning_of_month,
      source: :manual
    )

    assert_equal initial_allocated + 100, budget.allocated_to_goals
  end
end
