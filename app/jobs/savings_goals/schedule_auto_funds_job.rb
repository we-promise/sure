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
            .find_in_batches(batch_size: 1_000) do |families|
        enqueue_batch(families)
      end
    end

    private
      # Group the batch by each family's resolved month-start (which can shift
      # off the 1st via `custom_month_start_for` when month_start_day != 1),
      # then issue one budget SELECT per distinct start_date instead of one
      # per family. Bulk-enqueue the resulting jobs in one Redis round-trip.
      def enqueue_batch(families)
        by_start = families.group_by do |family|
          family.custom_month_start_for(Date.current.last_month)
        end

        jobs = []
        by_start.each do |start_date, fams|
          Budget.where(family_id: fams.map(&:id), start_date: start_date).each do |budget|
            jobs << SavingsGoals::AutoFundJob.new(budget.family_id, budget.id)
          end
        end

        ActiveJob.perform_all_later(jobs) if jobs.any?
      end
  end
end
