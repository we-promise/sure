require "test_helper"

class SavingsContributionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @goal = savings_goals(:vacation_italy)
    @depository = accounts(:depository)
    ensure_tailwind_build
  end

  test "new renders the modal form" do
    get new_savings_goal_contribution_url(@goal)
    assert_response :success
  end

  test "create saves a manual contribution" do
    assert_difference -> { @goal.savings_contributions.count } => 1 do
      post savings_goal_contributions_url(@goal), params: {
        savings_contribution: {
          amount: "100",
          contributed_at: Date.current.iso8601,
          notes: ""
        },
        savings_contribution_account_id: @depository.id
      }.merge(savings_contribution: { account_id: @depository.id, amount: "100", contributed_at: Date.current.iso8601 })
    end

    assert_redirected_to savings_goal_path(@goal)
    contribution = @goal.savings_contributions.order(created_at: :desc).first
    assert_equal "manual", contribution.source
    assert_equal @depository, contribution.account
  end

  test "create rejects contribution from non-linked account" do
    unlinked = Account.create!(family: @goal.family, accountable: Depository.new, name: "Unlinked", currency: "USD", balance: 100)
    assert_no_difference "@goal.savings_contributions.count" do
      post savings_goal_contributions_url(@goal), params: {
        savings_contribution: { amount: "10", contributed_at: Date.current.iso8601, account_id: unlinked.id }
      }
    end
    assert_response :unprocessable_entity
  end

  test "destroy manual contribution removes it" do
    manual = savings_contributions(:vacation_italy_manual)
    assert_difference "SavingsContribution.count", -1 do
      delete savings_goal_contribution_url(@goal, manual)
    end
  end

  test "destroy initial contribution is blocked" do
    initial = savings_contributions(:vacation_italy_initial)
    assert_no_difference "SavingsContribution.count" do
      delete savings_goal_contribution_url(@goal, initial)
    end
    assert_redirected_to savings_goal_path(@goal)
  end
end
