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
