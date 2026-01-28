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
  test "progress_percent returns correct percentage" do
    @goal.assign_attributes(target_amount: 1000, current_amount: 400)
    assert_equal 40.0, @goal.progress_percent
  end

  test "progress_percent caps at 100" do
    @goal.assign_attributes(target_amount: 100, current_amount: 150)
    assert_equal 100, @goal.progress_percent
  end

  test "remaining_amount returns correct amount" do
    @goal.assign_attributes(target_amount: 1000, current_amount: 400)
    assert_equal 600, @goal.remaining_amount
  end

  test "remaining_amount returns 0 if target reached" do
    @goal.assign_attributes(target_amount: 1000, current_amount: 1200)
    assert_equal 0, @goal.remaining_amount
  end

  test "on_track? returns true when no target date" do
    @goal.target_date = nil
    assert @goal.on_track?
  end

  test "pause! changes status from active to paused" do
    assert @goal.active?
    @goal.pause!
    assert @goal.paused?
  end

  test "pause! raises error if not active" do
    @goal.status = :paused
    assert_raises(SavingGoal::InvalidTransitionError) { @goal.pause! }
  end

  test "resume! changes status from paused to active" do
    @goal.status = :paused
    @goal.resume!
    assert @goal.active?
  end
end
