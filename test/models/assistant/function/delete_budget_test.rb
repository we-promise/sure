require "test_helper"

class Assistant::Function::DeleteBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::DeleteBudget.new(@user)
  end

  test "has correct name" do
    assert_equal "delete_budget", @function.name
  end

  test "deletes a named budget and its monthly data" do
    plan = budget_plans(:dylan_personal)
    Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)

    result = @function.call({ "budget" => "personal" })

    assert result[:success]
    assert_equal "Personal", result[:deleted_budget]
    assert_equal 1, result[:months_deleted]
    assert_not BudgetPlan.exists?(plan.id)
    assert_not Budget.exists?(budget_plan_id: plan.id)
  end

  test "refuses to delete the primary budget" do
    result = @function.call({ "budget" => "Primary" })

    assert_equal false, result[:success]
    assert_equal "cannot_delete_default", result[:error]
    assert BudgetPlan.exists?(budget_plans(:dylan_default).id)
  end

  test "reports unknown budgets" do
    result = @function.call({ "budget" => "Ghost" })

    assert_equal false, result[:success]
    assert_equal "invalid_params", result[:error]
    assert_match "Ghost", result[:message]
  end
end
