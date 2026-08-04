require "test_helper"

class Assistant::Function::GoalActionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @goal = goals(:vacation_italy)
  end

  test "lists goals with stable ids and linked account ids" do
    result = Assistant::Function::GetGoals.new(@user).call
    goal = result[:goals].find { |item| item[:id] == @goal.id }

    assert_equal @goal.name, goal[:name]
    assert_equal @goal.linked_account_ids.sort, goal[:linked_accounts].pluck(:id).sort
  end

  test "updates goal details linked accounts and state" do
    result = Assistant::Function::UpdateGoal.new(@user).call(
      "id" => @goal.id,
      "name" => "Italy 2027",
      "target_amount" => 6500,
      "target_date" => 8.months.from_now.to_date.iso8601,
      "linked_account_ids" => [ accounts(:depository).id ],
      "state" => "paused"
    )

    assert_equal true, result[:success]
    @goal.reload
    assert_equal "Italy 2027", @goal.name
    assert_equal 6500, @goal.target_amount
    assert_equal [ accounts(:depository).id ], @goal.linked_account_ids
    assert @goal.paused?
  end

  test "deletes an archived goal" do
    @goal.update!(state: "archived")
    Goal.any_instance.expects(:lock!).once

    result = Assistant::Function::DeleteGoal.new(@user).call("id" => @goal.id)

    assert_equal true, result[:success]
    assert_equal @goal.id, result[:deleted_goal_id]
    assert_not Goal.exists?(@goal.id)
  end

  test "requires a non-archived goal to be archived first" do
    result = Assistant::Function::DeleteGoal.new(@user).call("id" => @goal.id)

    assert_equal false, result[:success]
    assert_equal "archive_first", result[:error]
    assert Goal.exists?(@goal.id)
  end

  test "creates a goal from account ids returned by get_accounts" do
    account = accounts(:depository)

    result = Assistant::Function::CreateGoal.new(@user).call(
      "name" => "MCP Goal",
      "target_amount" => 900,
      "linked_account_ids" => [ account.id ]
    )

    assert_equal true, result[:success]
    assert_equal [ account.id ], Goal.find(result[:goal_id]).linked_account_ids
  end
end
