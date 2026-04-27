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

  test "auto_fund resolves the right budget for a custom-month-start family" do
    family = users(:family_admin).family
    family.update!(month_start_day: 15)

    travel_to Date.new(2026, 7, 20) do
      custom_start = family.custom_month_start_for(Date.current) # 2026-07-15
      custom_end = family.custom_month_end_for(Date.current)
      custom_budget = family.budgets.create!(
        start_date: custom_start, end_date: custom_end, currency: "USD"
      )

      # The route param "jul-2026" would, without family-aware parsing,
      # resolve to 2026-07-01 and find_or_bootstrap a different budget.
      # With family: passed through, it resolves to 2026-07-15.
      assert_enqueued_with(job: SavingsGoals::AutoFundJob, args: [ family.id, custom_budget.id ]) do
        post budget_savings_auto_fund_path(budget_month_year: Budget.date_to_param(custom_start))
      end
    end
  end
end
