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
    assert_equal @goal.linked_account_ids.sort, goal[:funding_accounts].pluck(:account_id).sort
    assert(goal[:funding_accounts].all? { |funding| funding[:allocation][:mode].in?(%w[whole_account fixed_amount]) })
  end

  test "updates goal details linked accounts and state" do
    account = @family.accounts.create!(owner: @user, name: "Goal update savings", accountable: Depository.new, balance: 1_000, currency: "USD")
    result = Assistant::Function::UpdateGoal.new(@user).call(
      "id" => @goal.id,
      "name" => "Italy 2027",
      "target_amount" => 6500,
      "target_date" => 8.months.from_now.to_date.iso8601,
      "funding_accounts" => [
        { "account_id" => account.id, "allocation" => { "mode" => "fixed_amount", "amount" => 500 } }
      ],
      "state" => "paused"
    )

    assert_equal true, result[:success]
    @goal.reload
    assert_equal "Italy 2027", @goal.name
    assert_equal 6500, @goal.target_amount
    assert_equal [ account.id ], @goal.linked_account_ids
    assert_equal 500, @goal.goal_accounts.first.allocated_amount.to_d
    assert @goal.paused?
  end

  test "deletes an archived goal" do
    @goal.update!(state: "archived")

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

  test "does not replace funding while the goal contains an inaccessible account" do
    member = users(:family_member)
    private_account = @family.accounts.create!(owner: @user, name: "Private goal funding", accountable: Depository.new, balance: 1_000, currency: "USD")
    replacement = @family.accounts.create!(owner: member, name: "Member replacement", accountable: Depository.new, balance: 1_000, currency: "USD")
    protected_goal = @family.goals.create!(name: "Protected funding", target_amount: 1_000, currency: "USD") do |goal|
      goal.goal_accounts.build(account: private_account, allocated_amount: 500)
    end

    result = Assistant::Function::UpdateGoal.new(member).call(
      "id" => protected_goal.id,
      "funding_accounts" => [
        { "account_id" => replacement.id, "allocation" => { "mode" => "fixed_amount", "amount" => 500 } }
      ]
    )

    assert_equal false, result[:success]
    assert_equal "inaccessible_existing_funding", result[:error]
    assert_equal [ private_account.id ], protected_goal.reload.linked_account_ids
  end

  test "does not replace funding while the goal contains a hidden account" do
    hidden_account = @family.accounts.create!(owner: @user, name: "Hidden goal funding", accountable: Depository.new, balance: 1_000, currency: "USD")
    replacement = @family.accounts.create!(owner: @user, name: "Visible replacement", accountable: Depository.new, balance: 1_000, currency: "USD")
    protected_goal = @family.goals.create!(name: "Hidden funding", target_amount: 1_000, currency: "USD") do |goal|
      goal.goal_accounts.build(account: hidden_account, allocated_amount: 500)
    end
    hidden_account.update!(status: "disabled")

    result = Assistant::Function::UpdateGoal.new(@user).call(
      "id" => protected_goal.id,
      "funding_accounts" => [
        { "account_id" => replacement.id, "allocation" => { "mode" => "fixed_amount", "amount" => 500 } }
      ]
    )

    assert_equal false, result[:success]
    assert_equal "inaccessible_existing_funding", result[:error]
    assert_equal [ hidden_account.id ], protected_goal.reload.linked_account_ids
  end

  test "creates a goal from account ids returned by get_accounts" do
    account = @family.accounts.create!(owner: @user, name: "MCP Goal savings", accountable: Depository.new, balance: 1_000, currency: "USD")

    result = Assistant::Function::CreateGoal.new(@user).call(
      "name" => "MCP Goal",
      "target_amount" => 900,
      "funding_accounts" => [
        { "account_id" => account.id, "allocation" => { "mode" => "whole_account" } }
      ]
    )

    assert_equal true, result[:success]
    assert_equal [ account.id ], Goal.find(result[:goal_id]).linked_account_ids
  end
end
