require "test_helper"

class SavingsGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @goal = savings_goals(:vacation)
    @account = accounts(:depository)
  end

  test "index lists active goals by default" do
    get savings_goals_path
    assert_response :success
    assert_select "body", text: /#{@goal.name}/
  end

  test "index supports state filter" do
    get savings_goals_path(state: "completed")
    assert_response :success
  end

  test "new renders form" do
    get new_savings_goal_path
    assert_response :success
  end

  test "create persists with valid params" do
    assert_difference -> { users(:family_admin).family.savings_goals.count }, +1 do
      post savings_goals_path, params: {
        savings_goal: {
          account_id: @account.id,
          name: "New trip",
          target_amount: 1500,
          target_date: 6.months.from_now.to_date,
          color: "#60A5FA"
        }
      }
    end
    goal = users(:family_admin).family.savings_goals.find_by(name: "New trip")
    assert_redirected_to savings_goal_path(goal)
  end

  test "create with initial contribution creates contribution" do
    assert_difference -> { SavingsContribution.where(source: "initial").count }, +1 do
      post savings_goals_path, params: {
        savings_goal: {
          account_id: @account.id,
          name: "With seed",
          target_amount: 1500,
          target_date: 6.months.from_now.to_date,
          initial_contribution: "100"
        }
      }
    end
  end

  test "create rejects an account that does not belong to the family" do
    other_family = Family.create!(name: "Other", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    other_account = other_family.accounts.create!(
      name: "Other depository", balance: 1000, currency: "USD",
      accountable: Depository.new
    )
    assert_no_difference -> { SavingsGoal.count } do
      post savings_goals_path, params: {
        savings_goal: {
          account_id: other_account.id,
          name: "Sneaky",
          target_amount: 100
        }
      }
    end
  end

  test "show renders" do
    get savings_goal_path(@goal)
    assert_response :success
  end

  test "update changes attributes" do
    patch savings_goal_path(@goal), params: { savings_goal: { name: "Renamed" } }
    assert_redirected_to savings_goal_path(@goal)
    assert_equal "Renamed", @goal.reload.name
  end

  test "destroy removes the goal" do
    assert_difference -> { SavingsGoal.count }, -1 do
      delete savings_goal_path(@goal)
    end
    assert_redirected_to savings_goals_path
  end

  test "lifecycle transitions" do
    patch pause_savings_goal_path(@goal)
    assert @goal.reload.paused?
    patch resume_savings_goal_path(@goal)
    assert @goal.reload.active?
    patch complete_savings_goal_path(@goal)
    assert @goal.reload.completed?
    patch archive_savings_goal_path(@goal)
    assert @goal.reload.archived?
    patch unarchive_savings_goal_path(@goal)
    assert @goal.reload.active?
  end

  test "cannot access another family's goal" do
    other_family = Family.create!(name: "Other", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    other_account = other_family.accounts.create!(
      name: "Other depository", balance: 1000, currency: "USD",
      accountable: Depository.new
    )
    foreign_goal = other_family.savings_goals.create!(
      account: other_account, name: "Theirs", target_amount: 100
    )
    get savings_goal_path(foreign_goal)
    assert_response :not_found
  end
end
