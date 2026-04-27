module Budgets
  class SavingsController < ApplicationController
    before_action :set_budget

    def show
      @savings_summary = Current.family.savings_summary_for(@budget)
    end

    def auto_fund
      SavingsGoals::AutoFundJob.perform_later(Current.family.id, @budget.id)
      redirect_to budget_savings_path(budget_month_year: Budget.date_to_param(@budget.start_date)),
                  notice: "Auto-funding has been queued."
    end

    private
      def set_budget
        start_date = Budget.param_to_date(params[:budget_month_year])
        @budget = Budget.find_or_bootstrap(Current.family, start_date: start_date)
        raise ActiveRecord::RecordNotFound unless @budget
      end
  end
end
