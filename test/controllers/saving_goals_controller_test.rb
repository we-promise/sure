require "test_helper"

class SavingGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @saving_goal = saving_goals(:emergency_fund)
    @family = @user.family
  end

  test "should get index" do
    get saving_goals_url
    assert_response :success
  end

  test "should get new" do
    get new_saving_goal_url
    assert_response :success
  end

  test "should create saving_goal" do
    assert_difference("SavingGoal.count") do
      post saving_goals_url, params: { saving_goal: { name: "New Goal", target_amount: 1000 } }
    end

    assert_redirected_to saving_goals_url
  end

  test "should show saving_goal" do
    get saving_goal_url(@saving_goal)
    assert_response :success
  end

  test "should get edit" do
    get edit_saving_goal_url(@saving_goal)
    assert_response :success
  end

  test "should update saving_goal" do
    patch saving_goal_url(@saving_goal), params: { saving_goal: { name: "Updated Name" } }
    assert_redirected_to saving_goals_url
  end

  test "should destroy saving_goal" do
    assert_difference("SavingGoal.count", -1) do
      delete saving_goal_url(@saving_goal)
    end

    assert_redirected_to saving_goals_url
  end

  test "should pause saving_goal" do
    post pause_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goal_url(@saving_goal)
    assert @saving_goal.reload.paused?
  end

  test "should resume saving_goal" do
    @saving_goal.pause!
    post resume_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goal_url(@saving_goal)
    assert @saving_goal.reload.active?
  end

  test "should complete saving_goal" do
    post complete_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goal_url(@saving_goal)
    assert @saving_goal.reload.completed?
  end

  test "should archive saving_goal" do
    post archive_saving_goal_url(@saving_goal)
    assert_redirected_to saving_goals_url
    assert @saving_goal.reload.archived?
  end
end
