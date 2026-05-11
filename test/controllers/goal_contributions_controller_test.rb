require "test_helper"

class GoalContributionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @goal = goals(:vacation_italy)
    @depository = accounts(:depository)
    ensure_tailwind_build
  end

  test "new renders the modal form" do
    get new_goal_contribution_url(@goal)
    assert_response :success
  end

  test "create saves a manual contribution" do
    assert_difference -> { @goal.goal_contributions.count } => 1 do
      post goal_contributions_url(@goal), params: {
        goal_contribution: {
          amount: "100",
          contributed_at: Date.current.iso8601,
          notes: ""
        },
        goal_contribution_account_id: @depository.id
      }.merge(goal_contribution: { account_id: @depository.id, amount: "100", contributed_at: Date.current.iso8601 })
    end

    assert_redirected_to goal_path(@goal)
    contribution = @goal.goal_contributions.order(created_at: :desc).first
    assert_equal "manual", contribution.source
    assert_equal @depository, contribution.account
  end

  test "create rejects contribution from non-linked account" do
    unlinked = Account.create!(family: @goal.family, accountable: Depository.new, name: "Unlinked", currency: "USD", balance: 100)
    assert_no_difference "@goal.goal_contributions.count" do
      post goal_contributions_url(@goal), params: {
        goal_contribution: { amount: "10", contributed_at: Date.current.iso8601, account_id: unlinked.id }
      }
    end
    assert_response :unprocessable_entity
  end

  test "destroy manual contribution removes it" do
    manual = goal_contributions(:vacation_italy_manual)
    assert_difference "GoalContribution.count", -1 do
      delete goal_contribution_url(@goal, manual)
    end
  end

  test "destroy initial contribution is blocked" do
    initial = goal_contributions(:vacation_italy_initial)
    assert_no_difference "GoalContribution.count" do
      delete goal_contribution_url(@goal, initial)
    end
    assert_redirected_to goal_path(@goal)
  end
end
