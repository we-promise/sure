module SavingsGoals
  # Cron entry point. Runs at the start of each month and enqueues a
  # per-family AutoFundJob against the previous month's budget.
  # Families without an active goal or without a closed budget are skipped.
  class ScheduleAutoFundsJob < ApplicationJob
    queue_as :scheduled

    def perform
      target_month_start = Date.current.last_month.beginning_of_month
      Family.joins(:savings_goals)
            .where(savings_goals: { state: "active" })
            .distinct
            .find_each do |family|
        budget = family.budgets.find_by(start_date: target_month_start)
        next unless budget
        SavingsGoals::AutoFundJob.perform_later(family.id, budget.id)
      end
    end
  end
end
