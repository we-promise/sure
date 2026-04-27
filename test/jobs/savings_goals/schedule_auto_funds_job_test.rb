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

  test "uses the family's custom month-start when resolving the previous-period budget" do
    # Family with `month_start_day = 15`. The previous period boundary is
    # the 15th of last month, not the 1st.
    @family.update!(month_start_day: 15)

    today = Date.new(2026, 7, 20)
    travel_to today do
      previous_period_start = @family.custom_month_start_for(today.last_month) # 2026-06-15

      custom_budget = @family.budgets.create!(
        start_date: previous_period_start,
        end_date: @family.custom_month_end_for(today.last_month),
        currency: "USD"
      )

      # The hardcoded `beginning_of_month` would have looked up 2026-06-01
      # and missed this budget entirely; the per-family fix resolves to
      # 2026-06-15.
      assert_enqueued_with(
        job: SavingsGoals::AutoFundJob,
        args: [ @family.id, custom_budget.id ]
      ) do
        SavingsGoals::ScheduleAutoFundsJob.new.perform
      end
    end
  end
end
