require "test_helper"

class Assistant::Function::ListBudgetsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::ListBudgets.new(@user)
  end

  test "has correct name" do
    assert_equal "list_budgets", @function.name
  end

  test "lists plans default-first with account scope and initialized month count" do
    plan = budget_plans(:dylan_personal)
    plan.budget_plan_accounts.create!(account: accounts(:depository))
    Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan).update!(budgeted_spending: 100)

    result = @function.call({})

    assert_equal @family.budget_plans.count, result[:budgets].length

    primary = result[:budgets].first
    assert primary[:is_default]
    assert_equal "all_accounts", primary[:accounts]
    assert_equal 1, primary[:initialized_months] # budgets(:one)

    personal = result[:budgets].find { |b| b[:slug] == "personal" }
    assert_equal [ accounts(:depository).name ], personal[:accounts]
    assert_equal 1, personal[:initialized_months]
  end
  test "hides linked accounts that aren't shared with the caller" do
    private_account = @family.accounts.create!(
      accountable: Depository.new,
      name: "Admin Private",
      status: "active",
      currency: "USD",
      balance: 0,
      owner: users(:family_admin)
    )
    plan = budget_plans(:dylan_personal)
    plan.budget_plan_accounts.create!(account: private_account)

    result = Assistant::Function::ListBudgets.new(users(:family_member)).call({})
    personal = result[:budgets].find { |b| b[:slug] == plan.slug }

    assert_equal [], personal[:accounts]
  end
end
