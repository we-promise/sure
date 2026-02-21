require "test_helper"

class SavingContributionTest < ActiveSupport::TestCase
  setup do
    @contribution = saving_contributions(:vacation_contribution_1)
    @goal = @contribution.saving_goal
  end

  test "valid contribution" do
    assert @contribution.valid?
  end

  test "invalid without amount" do
    @contribution.amount = nil
    refute @contribution.valid?
  end

  test "invalid with non-positive amount" do
    @contribution.amount = 0
    refute @contribution.valid?
  end

  test "invalid without month" do
    @contribution.month = nil
    refute @contribution.valid?
  end

  test "updates goal current_amount on create" do
    goal = saving_goals(:emergency_fund)
    initial_amount = goal.current_amount
    amount = 100

    contribution = goal.saving_contributions.create!(
      amount: amount,
      month: Date.current,
      currency: "USD"
    )

    assert_equal initial_amount + amount, goal.reload.current_amount
  end

  test "updates goal current_amount on destroy" do
    goal = @goal
    initial_amount = goal.current_amount
    amount = @contribution.amount

    @contribution.destroy

    assert_equal initial_amount - amount, goal.reload.current_amount
  end
end
