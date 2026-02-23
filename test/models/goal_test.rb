require "test_helper"

class GoalTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @goal = goals(:emergency_fund)
  end

  test "validates name presence" do
    goal = Goal.new(family: @family, target_amount: 1000, currency: "USD")
    refute goal.valid?
    assert goal.errors[:name].any?
  end

  test "validates target_amount greater than zero" do
    goal = Goal.new(family: @family, name: "Test", target_amount: 0, currency: "USD")
    refute goal.valid?
    assert goal.errors[:target_amount].any?
  end

  test "validates goal_type inclusion" do
    goal = Goal.new(family: @family, name: "Test", target_amount: 1000, currency: "USD", goal_type: "invalid")
    refute goal.valid?
    assert goal.errors[:goal_type].any?
  end

  test "validates color is a valid hex code" do
    goal = Goal.new(family: @family, name: "Test", target_amount: 1000, currency: "USD", goal_type: "custom")

    goal.color = "#ff0000"
    goal.valid?
    assert_empty goal.errors[:color]

    goal.color = "not-a-color"
    refute goal.valid?
    assert goal.errors[:color].any?

    goal.color = "#ff00"
    refute goal.valid?
    assert goal.errors[:color].any?

    goal.color = nil
    goal.valid?
    assert_empty goal.errors[:color]
  end

  test "progress_percent computes correctly" do
    assert_equal 30.0, @goal.progress_percent
  end

  test "progress_percent caps at 100" do
    @goal.current_amount = 15000
    assert_equal 100, @goal.progress_percent
  end

  test "remaining_amount computes correctly" do
    assert_equal 7000, @goal.remaining_amount
  end

  test "remaining_amount does not go below zero" do
    @goal.current_amount = 15000
    assert_equal 0, @goal.remaining_amount
  end

  test "days_remaining returns correct value" do
    @goal.target_date = Date.current + 30
    assert_equal 30, @goal.days_remaining
  end

  test "days_remaining returns zero when target_date is past" do
    @goal.target_date = Date.current - 5
    assert_equal 0, @goal.days_remaining
  end

  test "days_remaining returns zero when no target_date" do
    @goal.target_date = nil
    assert_equal 0, @goal.days_remaining
  end

  test "on_track? returns true when completed" do
    completed = goals(:completed_goal)
    assert completed.on_track?
  end

  test "on_track? returns true when no target_date" do
    @goal.target_date = nil
    assert @goal.on_track?
  end

  test "normalizes blank current_amount to zero" do
    goal = Goal.new(family: @family, name: "Test", target_amount: 1000, currency: "USD", goal_type: "custom", current_amount: "")
    goal.valid?
    assert_equal 0, goal.current_amount
  end

  test "computed_current_amount uses account balance when linked" do
    account = accounts(:depository)
    @goal.update!(account: account)
    assert_equal account.balance, @goal.computed_current_amount
  end

  test "computed_current_amount uses current_amount when no linked categories" do
    assert_equal @goal.current_amount, @goal.computed_current_amount
  end

  test "computed_current_amount sums linked category actuals" do
    budget = budgets(:one)
    savings_category = categories(:savings)

    bc = BudgetCategory.create!(
      budget: budget,
      category: savings_category,
      budgeted_spending: 500,
      currency: "USD",
      goal: @goal
    )

    Budget.any_instance.stubs(:budget_category_actual_spending).returns(250)

    assert_equal 250, @goal.reload.computed_current_amount
  end

  test "goal_type_icon returns correct icon" do
    assert_equal "shield", @goal.goal_type_icon

    @goal.goal_type = "vacation"
    assert_equal "plane", @goal.goal_type_icon
  end

  test "scopes return correct results" do
    assert_includes Goal.active, goals(:emergency_fund)
    assert_includes Goal.active, goals(:vacation)
    refute_includes Goal.active, goals(:completed_goal)

    assert_includes Goal.completed, goals(:completed_goal)
    refute_includes Goal.completed, goals(:emergency_fund)
  end
end
