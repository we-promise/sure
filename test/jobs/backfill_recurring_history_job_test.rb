require "test_helper"

# The deferred half of reconstructing a bill's history: activating a detected
# bill queues this when a pipeline holds the family lock, rather than skipping
# the backfill.
class BackfillRecurringHistoryJobTest < ActiveJob::TestCase
  include FamilyLockTestHelper
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @paid_on = Date.current.beginning_of_month + 8.days - 2.months

    @series = @family.recurring_transactions.create!(
      name: "CITY WATER", account: @account, amount: 80, currency: "USD",
      expected_day_of_month: 9, last_occurrence_date: @paid_on,
      next_expected_date: @paid_on + 2.months, status: "suggested", manual: false
    )
    @entry = @account.entries.create!(
      date: @paid_on, amount: 80, currency: "USD", name: "CITY WATER",
      entryable: Transaction.new
    )
  end

  test "links the past payment of a bill that is still active" do
    activate_without_callbacks(@series)

    assert_difference -> { paid_past_occurrences }, 1 do
      BackfillRecurringHistoryJob.perform_now(@series.id)
    end
    assert RecurringAllocation.where(entry_id: @entry.id, state: "confirmed").exists?
  end

  test "does nothing for a bill dismissed before the job ran" do
    occurrence = open_occurrence_on_payment_date
    @series.update_columns(status: "ended")

    BackfillRecurringHistoryJob.perform_now(@series.id)

    assert_not RecurringAllocation.where(entry_id: @entry.id).exists?,
      "the payment must not be written onto a bill the user set aside"
    assert occurrence.reload.scheduled?
  end

  test "does nothing for a bill paused before the job ran" do
    occurrence = open_occurrence_on_payment_date
    @series.update_columns(status: "inactive")

    BackfillRecurringHistoryJob.perform_now(@series.id)

    assert_not RecurringAllocation.where(entry_id: @entry.id).exists?,
      "the payment must not be written onto a bill the user set aside"
    assert occurrence.reload.scheduled?
  end

  test "does nothing for a bill deleted before the job ran" do
    id = @series.id
    @series.destroy!

    assert_nothing_raised { BackfillRecurringHistoryJob.perform_now(id) }
    assert_not RecurringAllocation.where(entry_id: @entry.id).exists?
  end

  test "does nothing for a family that has turned bills off" do
    activate_without_callbacks(@series)
    @family.update!(recurring_transactions_disabled: true)

    assert_no_enqueued_jobs(only: BackfillRecurringHistoryJob) do
      BackfillRecurringHistoryJob.perform_now(@series.id)
    end
    assert_equal 0, paid_past_occurrences
  end

  # The job's status check reads a record that a pause can overtake. The
  # pause's own regeneration clears the upcoming rows, so the rebuild must
  # read the status afresh rather than put them back on a paused bill.
  test "a bill paused after the job loaded it gains no occurrences" do
    activate_without_callbacks(@series)
    loaded = RecurringTransaction.find(@series.id)
    RecurringTransaction.where(id: @series.id).update_all(status: "inactive")

    assert_no_difference -> { @series.recurring_occurrences.count } do
      loaded.reconstruct_history!
    end
  end

  test "tries again later while a pipeline still holds the family lock" do
    activate_without_callbacks(@series)

    with_family_lock_held_elsewhere(@family.id) do
      assert_enqueued_with(job: BackfillRecurringHistoryJob, args: [ @series.id ]) do
        BackfillRecurringHistoryJob.perform_now(@series.id)
      end
    end

    assert_equal 0, paid_past_occurrences, "nothing may run while the lock is held"
  end

  private
    # Puts the series in the state the job finds after a contended confirm:
    # active, with the callback's own backfill not having run.
    def activate_without_callbacks(series)
      series.update_columns(status: "active")
    end

    # An open row the bill already had on the payment date: a backfill run
    # against it links the entry, which is what the status guard must stop.
    def open_occurrence_on_payment_date
      @series.recurring_occurrences.create!(
        family: @family, original_due_on: @paid_on, due_on: @paid_on, currency: "USD"
      )
    end

    def paid_past_occurrences
      @series.recurring_occurrences.paid.where(due_on: @paid_on).count
    end
end
