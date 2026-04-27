require "test_helper"

class SavingsContributionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @goal = savings_goals(:vacation)
    @budget = budgets(:one)
  end

  test "new renders form" do
    get new_savings_goal_contribution_path(@goal)
    assert_response :success
  end

  test "create persists a manual contribution" do
    assert_difference -> { @goal.savings_contributions.manual.count }, +1 do
      post savings_goal_contributions_path(@goal), params: {
        savings_contribution: {
          amount: 50, contributed_at: Date.current, notes: "Bonus"
        }
      }
    end
    assert_redirected_to savings_goal_path(@goal)
    contribution = @goal.savings_contributions.recent_first.first
    assert_nil contribution.budget_id, "manual contributions are no longer tagged to a budget"
  end

  test "destroy removes the contribution and redirects to the goal" do
    contribution = savings_contributions(:vacation_manual_top_up)
    assert_difference -> { @goal.savings_contributions.count }, -1 do
      delete savings_goal_contribution_path(@goal, contribution)
    end
    assert_redirected_to savings_goal_path(@goal)
  end

  test "cannot create for another family's goal" do
    other_family = Family.create!(name: "Other", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    other_account = other_family.accounts.create!(
      name: "Other depository", balance: 1000, currency: "USD",
      accountable: Depository.new
    )
    foreign_goal = other_family.savings_goals.create!(
      account: other_account, name: "Theirs", target_amount: 100
    )
    post savings_goal_contributions_path(foreign_goal), params: {
      savings_contribution: { amount: 10 }
    }
    assert_response :not_found
  end
end
