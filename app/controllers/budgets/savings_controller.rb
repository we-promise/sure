module Budgets
  class SavingsController < ApplicationController
    before_action :set_budget

    def auto_fund
      SavingsGoals::AutoFundJob.perform_later(Current.family.id, @budget.id)
      redirect_to budget_path(Budget.date_to_param(@budget.start_date)),
                  notice: t("budgets.savings.auto_fund.success")
    end

    private
      # Pass `family:` so families with a non-default `month_start_day`
      # parse the route param to their own boundary (e.g. the 15th)
      # instead of falling through to `beginning_of_month`. Mirrors the
      # upstream BudgetsController#set_budget signature.
      def set_budget
        start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
        @budget = Budget.find_or_bootstrap(Current.family, start_date: start_date, user: Current.user)
        raise ActiveRecord::RecordNotFound unless @budget
      end
  end
end
