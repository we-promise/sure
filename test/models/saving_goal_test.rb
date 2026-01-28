require "test_helper"

class SavingGoalTest < ActiveSupport::TestCase
  setup do
    @goal = saving_goals(:emergency_fund)
  end

  test "valid goal" do
    assert @goal.valid?
  end

  test "invalid without name" do
    @goal.name = nil
    refute @goal.valid?
  end

  test "invalid with non-positive target amount" do
    @goal.target_amount = 0
    refute @goal.valid?
    @goal.target_amount = -1
    refute @goal.valid?
  end

  test "invalid without currency" do
    @goal.currency = nil
    refute @goal.valid?
  end

  test "associations" do
    assert_respond_to @goal, :saving_contributions
    assert_respond_to @goal, :family
  end
end
