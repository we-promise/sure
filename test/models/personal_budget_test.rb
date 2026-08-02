require "test_helper"

class PersonalBudgetTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user1 = users(:josh)
    @user2 = users(:ann)
    @date = Date.current.beginning_of_month
  end

  test "shared budget by default" do
    @family.update!(personal_budgets: false)

    budget1 = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)
    budget2 = Budget.find_or_bootstrap(@family, start_date: @date, user: @user2)

    assert_equal budget1.id, budget2.id
    assert_nil budget1.user_id
  end

  test "separate budgets when personal_budgets is enabled" do
    @family.update!(personal_budgets: true)

    budget1 = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)
    budget2 = Budget.find_or_bootstrap(@family, start_date: @date, user: @user2)

    assert_not_equal budget1.id, budget2.id
    assert_equal @user1.id, budget1.user_id
    assert_equal @user2.id, budget2.user_id
  end

  test "find_or_bootstrap handles transition from shared to personal" do
    @family.update!(personal_budgets: false)
    shared_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)

    @family.update!(personal_budgets: true)
    personal_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)

    assert_not_equal shared_budget.id, personal_budget.id
    assert_equal @user1.id, personal_budget.user_id
  end

  test "most_recent_initialized_budget does not bleed across users" do
    @family.update!(personal_budgets: true)

    past_date = 1.month.ago.beginning_of_month

    # user1 has an initialized budget last month
    user1_past = Budget.find_or_bootstrap(@family, start_date: past_date, user: @user1)
    user1_past.update!(budgeted_spending: 3000, expected_income: 5000)

    # user2 has no budget last month — creates a fresh one for this month
    user2_current = Budget.find_or_bootstrap(@family, start_date: @date, user: @user2)

    # user2's source should be nil, not user1's past budget
    assert_nil user2_current.most_recent_initialized_budget
  end

  test "copy_previous does not copy another users budget" do
    @family.update!(personal_budgets: true)

    past_date = 1.month.ago.beginning_of_month

    user1_past = Budget.find_or_bootstrap(@family, start_date: past_date, user: @user1)
    user1_past.update!(budgeted_spending: 9999, expected_income: 9999)

    user2_current = Budget.find_or_bootstrap(@family, start_date: @date, user: @user2)

    # copy_from! should not find user1's budget as source
    source = user2_current.most_recent_initialized_budget
    assert_nil source
    assert_nil user2_current.budgeted_spending
  end
end
