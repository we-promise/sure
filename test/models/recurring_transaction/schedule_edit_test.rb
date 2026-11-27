require "test_helper"

class RecurringTransaction::ScheduleEditTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
  end

  test "a dry run reports what the save does and commits nothing" do
    travel_to Date.new(2026, 11, 23) do
      series = weekly_series
      before = occurrence_rows(series)

      preview = edit(move_to_friday(series)).save(dry_run: true)

      assert_equal before, occurrence_rows(series), "a dry run must leave every row as it was"
      assert_equal 2, RecurringTransaction.find(series.id).recurrence_rules.sole.weekday

      applied = edit(move_to_friday(RecurringTransaction.find(series.id))).save

      assert_equal preview, applied
      assert_includes applied.created, Date.new(2026, 11, 27)
      assert_includes applied.removed, Date.new(2026, 11, 24)
      assert_not_equal before, occurrence_rows(series)
    end
  end

  test "an invalid series returns nil, keeps its errors and writes nothing" do
    travel_to Date.new(2026, 11, 23) do
      series = weekly_series
      series.recurring_occurrences.create!(family: @family, original_due_on: Date.new(2026, 11, 10),
                                           due_on: Date.new(2026, 11, 10), currency: "USD")
      before = occurrence_rows(series)
      series.amount = nil

      result = RecurringTransaction::ScheduleEdit.new(series, anchor: Date.new(2026, 11, 24),
                                                              skip_open_before_anchor: true).save

      assert_nil result
      assert series.errors.any?
      assert_equal before, occurrence_rows(series), "the skip is rolled back with the failed save"
    end
  end

  test "skipping before the anchor leaves rows with any allocation, and today onwards, alone" do
    travel_to Date.new(2026, 11, 23) do
      series = weekly_series
      paid_part = series.recurring_occurrences.create!(family: @family, original_due_on: Date.new(2026, 11, 3),
                                                       due_on: Date.new(2026, 11, 3), currency: "USD")
      paid_part.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created")
      unpaid = series.recurring_occurrences.create!(family: @family, original_due_on: Date.new(2026, 11, 10),
                                                    due_on: Date.new(2026, 11, 10), currency: "USD")

      series.restart_schedule_on(Date.new(2026, 12, 1))
      report = RecurringTransaction::ScheduleEdit.new(series, anchor: Date.new(2026, 12, 1),
                                                              skip_open_before_anchor: true).save

      assert unpaid.reload.skipped?
      assert paid_part.reload.scheduled?, "a partially paid occurrence is never touched"
      assert_equal [ Date.new(2026, 11, 10), Date.new(2026, 11, 17) ], report.skipped
      assert_equal [ Date.new(2026, 11, 3) ], report.left_open_before_anchor
      assert_includes report.removed, Date.new(2026, 11, 24), "a future open date is rebuilt, not skipped"
    end
  end

  private

    def edit(series)
      RecurringTransaction::ScheduleEdit.new(series)
    end

    # Weekly on Tuesdays, declared on 2026-11-17.
    def weekly_series
      series = @family.recurring_transactions.new(
        name: "Cleaner", amount: 20, currency: "USD", dedup_scope: "cleaner",
        expected_day_of_month: 17, anchor_date: Date.new(2026, 11, 17),
        last_occurrence_date: Date.new(2026, 11, 17), next_expected_date: Date.new(2026, 11, 24),
        status: "active", manual: true
      )
      RecurringTransaction::FrequencyPreset.apply(series, preset: "weekly", weekday: 2)
      series.save!
      series
    end

    def move_to_friday(series)
      RecurringTransaction::FrequencyPreset.apply(series, preset: "weekly", weekday: 5)
      series
    end

    def occurrence_rows(series)
      RecurringOccurrence.where(recurring_transaction_id: series.id).order(:id).map(&:attributes)
    end
end
