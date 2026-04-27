require "test_helper"

class Savings::GoalCardComponentTest < ViewComponent::TestCase
  setup do
    @goal = savings_goals(:vacation)
  end

  test "links to the goal show page" do
    render_inline Savings::GoalCardComponent.new(goal: @goal)
    assert_selector "a[href='/savings_goals/#{@goal.id}']"
  end

  test "renders state badge" do
    render_inline Savings::GoalCardComponent.new(goal: @goal)
    assert_selector "span", text: "Active"
  end
end

class Savings::GoalCardComponentStatePillTest < ViewComponent::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "active pill uses success token" do
    goal = @family.savings_goals.create!(account: @account, name: "x", target_amount: 100, state: "active")
    rendered = render_inline Savings::GoalCardComponent.new(goal: goal)
    assert_selector "span.bg-success\\/10.text-success", text: "Active"
  end

  test "paused pill uses warning token" do
    goal = @family.savings_goals.create!(account: @account, name: "x", target_amount: 100, state: "paused")
    rendered = render_inline Savings::GoalCardComponent.new(goal: goal)
    assert_selector "span.bg-warning\\/10.text-warning", text: "Paused"
  end

  test "completed pill uses success token (heavier)" do
    goal = @family.savings_goals.create!(account: @account, name: "x", target_amount: 100, state: "completed")
    rendered = render_inline Savings::GoalCardComponent.new(goal: goal)
    assert_selector "span.bg-success\\/20.text-success", text: "Completed"
  end

  test "archived pill uses neutral container-inset" do
    goal = @family.savings_goals.create!(account: @account, name: "x", target_amount: 100, state: "archived")
    rendered = render_inline Savings::GoalCardComponent.new(goal: goal)
    assert_selector "span.bg-container-inset.text-secondary", text: "Archived"
  end

  test "subtitle falls back to account name when no target_date" do
    goal = @family.savings_goals.create!(account: @account, name: "x", target_amount: 100)
    rendered = render_inline Savings::GoalCardComponent.new(goal: goal)
    assert_selector "p", text: @account.name
  end
end
