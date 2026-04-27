require "test_helper"

class SavingsGoals::ScheduleAutoFundsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)
  end

  test "enqueues AutoFundJob per family for the previous month budget" do
    target_start = @budget.start_date
    travel_to target_start.next_month do
      assert_enqueued_with(
        job: SavingsGoals::AutoFundJob,
        args: [ @family.id, @budget.id ],
        queue: "medium_priority"
      ) do
        SavingsGoals::ScheduleAutoFundsJob.new.perform
      end
    end
  end

  test "skips families that have no budget for the target month" do
    target_start = @budget.start_date
    # If we travel two months ahead, the cron looks at last_month = target_start.next_month,
    # for which no budget exists, so no job should enqueue for this family.
    travel_to target_start.next_month.next_month do
      assert_no_enqueued_jobs(only: SavingsGoals::AutoFundJob) do
        SavingsGoals::ScheduleAutoFundsJob.new.perform
      end
    end
  end
end
