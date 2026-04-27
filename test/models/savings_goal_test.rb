require "test_helper"

class SavingsGoalTest < ActiveSupport::TestCase
  setup do
    @goal = savings_goals(:vacation)
  end

  test "valid fixture" do
    assert @goal.valid?
  end

  test "requires name, target_amount, currency" do
    goal = SavingsGoal.new(family: families(:dylan_family))
    assert_not goal.valid?
    assert_includes goal.errors.attribute_names, :name
    assert_includes goal.errors.attribute_names, :target_amount
    assert_includes goal.errors.attribute_names, :currency
  end

  test "rejects non-positive target_amount" do
    @goal.target_amount = 0
    assert_not @goal.valid?
    @goal.target_amount = -50
    assert_not @goal.valid?
  end

  test "starts in active state" do
    goal = SavingsGoal.create!(
      family: families(:dylan_family),
      name: "New goal",
      target_amount: 100,
      currency: "USD"
    )
    assert goal.active?
  end

  test "lifecycle transitions" do
    @goal.pause!
    assert @goal.paused?
    @goal.resume!
    assert @goal.active?
    @goal.complete!
    assert @goal.completed?
    @goal.archive!
    assert @goal.archived?
    @goal.unarchive!
    assert @goal.active?
  end

  test "current_balance sums contributions" do
    assert_equal 1250.00, @goal.current_balance
  end

  test "remaining_amount clamps to zero when over target" do
    SavingsContribution.create!(
      savings_goal: @goal, amount: 10_000, currency: "USD",
      source: "manual", contributed_at: Date.current
    )
    assert_equal 0, @goal.remaining_amount
  end

  test "progress_percent caps at 100" do
    assert_operator @goal.progress_percent, :<=, 100
  end

  test "progress_percent is 100 once completed" do
    assert_equal 100, savings_goals(:paid_off_car).progress_percent
  end

  test "months_remaining nil when no target_date" do
    assert_nil savings_goals(:paid_off_car).months_remaining
  end

  test "monthly_target_amount nil when no target_date" do
    assert_nil savings_goals(:paid_off_car).monthly_target_amount
  end

  test "monthly_target_amount divides remaining by months" do
    @goal.target_date = 5.months.from_now.to_date
    expected = (@goal.remaining_amount.to_d / @goal.months_remaining).ceil(2)
    assert_equal expected, @goal.monthly_target_amount
  end

  test "destroy cascades contributions" do
    contribution_ids = @goal.savings_contributions.pluck(:id)
    @goal.destroy
    assert_equal 0, SavingsContribution.where(id: contribution_ids).count
  end
end
