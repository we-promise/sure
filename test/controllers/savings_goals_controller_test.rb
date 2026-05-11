require "test_helper"

class SavingsGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @goal = savings_goals(:vacation_italy)
    @depository = accounts(:depository)
    @connected = accounts(:connected)
    ensure_tailwind_build
  end

  test "index renders with active filter by default" do
    get savings_goals_url
    assert_response :success
    assert_match(/Savings/i, response.body)
  end

  test "index honors state filter" do
    get savings_goals_url(state: "paused")
    assert_response :success
  end

  test "show renders the goal" do
    get savings_goal_url(@goal)
    assert_response :success
    assert_match(@goal.name, response.body)
  end

  test "new renders the modal form" do
    get new_savings_goal_url
    assert_response :success
  end

  test "create persists a goal with linked accounts" do
    assert_difference -> { SavingsGoal.count } => 1,
                      -> { SavingsGoalAccount.count } => 2 do
      post savings_goals_url, params: {
        savings_goal: {
          name: "New goal",
          target_amount: "1000",
          target_date: 3.months.from_now.to_date.iso8601,
          color: "#4da568",
          account_ids: [ @depository.id, @connected.id ]
        }
      }
    end

    goal = SavingsGoal.order(created_at: :desc).first
    assert_redirected_to savings_goal_path(goal)
  end

  test "create with initial contribution writes the contribution" do
    assert_difference -> { SavingsContribution.count } => 1 do
      post savings_goals_url, params: {
        savings_goal: {
          name: "Goal with initial",
          target_amount: "1000",
          color: "#4da568",
          account_ids: [ @depository.id ],
          initial_contribution_amount: "50",
          initial_contribution_account_id: @depository.id
        }
      }
    end

    contribution = SavingsContribution.order(created_at: :desc).first
    assert_equal "initial", contribution.source
    assert_equal 50, contribution.amount.to_i
  end

  test "create rejects missing account_ids" do
    assert_no_difference "SavingsGoal.count" do
      post savings_goals_url, params: {
        savings_goal: {
          name: "Bad goal",
          target_amount: "1000",
          color: "#4da568"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create rejects foreign accounts" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)

    assert_no_difference "SavingsGoal.count" do
      post savings_goals_url, params: {
        savings_goal: {
          name: "Foreign goal",
          target_amount: "1000",
          color: "#4da568",
          account_ids: [ foreign.id ]
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "update modifies identity fields" do
    patch savings_goal_url(@goal), params: { savings_goal: { name: "Renamed" } }
    assert_redirected_to savings_goal_path(@goal)
    assert_equal "Renamed", @goal.reload.name
  end

  test "pause/resume/complete/archive/unarchive flow" do
    fresh = savings_goals(:emergency_fund)
    patch pause_savings_goal_url(fresh)
    assert fresh.reload.paused?
    patch resume_savings_goal_url(fresh)
    assert fresh.reload.active?
    patch complete_savings_goal_url(fresh)
    assert fresh.reload.completed?
    patch archive_savings_goal_url(fresh)
    assert fresh.reload.archived?
    patch unarchive_savings_goal_url(fresh)
    assert fresh.reload.active?
  end

  test "destroy on non-archived is rejected" do
    assert_no_difference "SavingsGoal.count" do
      delete savings_goal_url(@goal)
    end
    assert_redirected_to savings_goal_path(@goal)
  end

  test "destroy on archived deletes" do
    @goal.archive!
    assert_difference "SavingsGoal.count", -1 do
      delete savings_goal_url(@goal)
    end
    assert_redirected_to savings_goals_path
  end

  test "another family's goal returns 404" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_account = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)
    other_goal = other_family.savings_goals.new(name: "Foreign goal", target_amount: 100, currency: "USD")
    other_goal.savings_goal_accounts.build(account: other_account)
    other_goal.save!

    get savings_goal_url(other_goal)
    assert_response :not_found
  end
end
