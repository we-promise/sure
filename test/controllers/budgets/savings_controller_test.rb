require "test_helper"

class Budgets::SavingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @budget = budgets(:one)
    @month_year = Budget.date_to_param(@budget.start_date)
  end

  test "auto_fund enqueues AutoFundJob and redirects to the budget" do
    assert_enqueued_with(job: SavingsGoals::AutoFundJob, args: [ users(:family_admin).family.id, @budget.id ]) do
      post budget_savings_auto_fund_path(budget_month_year: @month_year)
    end
    assert_redirected_to budget_path(@month_year)
  end
end
