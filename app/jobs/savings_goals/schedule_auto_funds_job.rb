module SavingsGoals
  # Cron entry point. Runs at the start of each month and enqueues a
  # per-family AutoFundJob against the previous month's budget.
  # Families without an active goal or without a closed budget are skipped.
  class ScheduleAutoFundsJob < ApplicationJob
    queue_as :scheduled

    def perform
      Family.joins(:savings_goals)
            .where(savings_goals: { state: "active" })
            .distinct
            .find_each do |family|
        # Compute target_month_start per family so families with a
        # non-default month_start_day (e.g. 15th) resolve to their own
        # boundary instead of `beginning_of_month`.
        # `custom_month_start_for` returns the 1st when month_start_day
        # is 1, so this is correct for default families too.
        target_month_start = family.custom_month_start_for(Date.current.last_month)
        budget = family.budgets.find_by(start_date: target_month_start)
        next unless budget
        SavingsGoals::AutoFundJob.perform_later(family.id, budget.id)
      end
    end
  end
end
