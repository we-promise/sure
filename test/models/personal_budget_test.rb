require "test_helper"

class PersonalBudgetTest < ActiveSupport::TestCase
  include EntriesTestHelper

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

  test "copy_from! rejects a source budget owned by another user" do
    @family.update!(personal_budgets: true)

    past_date = 1.month.ago.beginning_of_month

    user1_past = Budget.find_or_bootstrap(@family, start_date: past_date, user: @user1)
    user1_past.update!(budgeted_spending: 9999, expected_income: 9999)

    user2_current = Budget.find_or_bootstrap(@family, start_date: @date, user: @user2)

    assert_raises(ArgumentError) { user2_current.copy_from!(user1_past) }
  end

  test "deleting a user cascades through their personal budget and budget categories" do
    @family.update!(personal_budgets: true)
    category = @family.categories.create!(name: "Groceries", color: "#6172F3")

    budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)
    budget.update!(budgeted_spending: 500, expected_income: 1000)
    budget_category = budget.budget_categories.find_by!(category_id: category.id)

    assert_nothing_raised { @user1.destroy! }

    assert_nil Budget.find_by(id: budget.id)
    assert_nil BudgetCategory.find_by(id: budget_category.id)
  end

  test "household and personal budgets coexist when household: true is explicitly requested" do
    @family.update!(personal_budgets: true)

    household_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1, household: true)
    personal_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)

    assert_not_equal household_budget.id, personal_budget.id
    assert_nil household_budget.user_id
    assert_equal @user1.id, personal_budget.user_id
  end

  test "household: true returns nil when the family disabled household_budget_enabled" do
    @family.update!(personal_budgets: true, household_budget_enabled: false)

    assert_nil Budget.find_or_bootstrap(@family, start_date: @date, user: @user1, household: true)
  end

  test "household: true ignores household_budget_enabled when personal_budgets is off" do
    @family.update!(personal_budgets: false, household_budget_enabled: false)

    budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1, household: true)

    assert budget.present?
    assert_nil budget.user_id
  end

  test "viewable_by? and editable_by? allow every family member on the household budget" do
    household_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1, household: true)

    assert household_budget.viewable_by?(@user1)
    assert household_budget.viewable_by?(@user2)
    assert household_budget.editable_by?(@user1)
    assert household_budget.editable_by?(@user2)
  end

  test "viewable_by? and editable_by? restrict a personal budget to its owner by default" do
    @family.update!(personal_budgets: true)
    personal_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)

    assert personal_budget.viewable_by?(@user1)
    assert personal_budget.editable_by?(@user1)
    assert_not personal_budget.viewable_by?(@user2)
    assert_not personal_budget.editable_by?(@user2)
  end

  test "a read_only BudgetShare grants viewing but not editing" do
    @family.update!(personal_budgets: true)
    personal_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)
    BudgetShare.create!(owner: @user1, viewer: @user2, permission: "read_only")

    assert personal_budget.viewable_by?(@user2)
    assert_not personal_budget.editable_by?(@user2)
  end

  test "a read_write BudgetShare grants both viewing and editing" do
    @family.update!(personal_budgets: true)
    personal_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)
    BudgetShare.create!(owner: @user1, viewer: @user2, permission: "read_write")

    assert personal_budget.viewable_by?(@user2)
    assert personal_budget.editable_by?(@user2)
  end

  test "household actual spending reflects the viewer's accessible accounts, personal reflects only the owner's own" do
    @family.update!(personal_budgets: true)

    owned_account = Account.create!(family: @family, accountable: Depository.new, name: "Josh checking", status: "active", currency: "USD", balance: 0, owner: @user1)
    joint_account = Account.create!(family: @family, accountable: Depository.new, name: "Joint savings", status: "active", currency: "USD", balance: 0, owner: @user2)
    AccountShare.create!(account: joint_account, user: @user1, permission: "read_write", include_in_finances: true)

    create_transaction(account: owned_account, amount: 50, date: @date)
    create_transaction(account: joint_account, amount: 200, date: @date)

    household_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1, household: true)
    personal_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @user1)

    assert_equal 250.0, household_budget.actual_spending.to_f
    assert_equal 50.0, personal_budget.actual_spending.to_f
  end
end
