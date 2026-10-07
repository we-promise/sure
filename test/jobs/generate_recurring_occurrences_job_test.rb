require "test_helper"

class GenerateRecurringOccurrencesJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "without args enqueues one job per non-disabled family" do
    assert_enqueued_jobs Family.count, only: GenerateRecurringOccurrencesJob do
      GenerateRecurringOccurrencesJob.perform_now
    end
  end

  test "does nothing for an unknown family" do
    assert_nothing_raised do
      GenerateRecurringOccurrencesJob.perform_now(SecureRandom.uuid)
    end
  end

  test "generates occurrences for active recurring transactions" do
    series = recurring_transactions(:netflix_subscription)
    series.recurring_occurrences.delete_all

    assert_difference "RecurringOccurrence.count", :+, 1 do
      travel_to Date.new(2026, 8, 13) do
        GenerateRecurringOccurrencesJob.perform_now(@family.id)
      end
    end
  end

  test "does not issue one recurrence_rules query per active series (no N+1)" do
    # Ensure we have at least two active series so an N+1 would be observable.
    series1 = recurring_transactions(:netflix_subscription)
    series2 = @family.recurring_transactions.create!(
      account: series1.account,
      amount: 9.99,
      currency: "USD",
      status: "active",
      expected_day_of_month: 10,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      occurrence_count: 1
    )
    RecurringTransaction::FrequencyPreset.apply(series2, preset: "monthly", day_of_month: "10")
    series2.save!

    active_count = @family.recurring_transactions.active.count
    assert_operator active_count, :>=, 2, "need at least 2 active series to detect an N+1"

    queries = capture_sql_queries do
      travel_to Date.new(2026, 8, 13) do
        GenerateRecurringOccurrencesJob.perform_now(@family.id)
      end
    end

    recurrence_rule_queries = queries.select { |q| q.include?("recurrence_rules") }

    # With preloading there should be exactly one IN-query covering all series,
    # not one per-series = query for each of the active_count series.
    assert_operator recurrence_rule_queries.size, :<, active_count,
      "Expected recurrence_rules to be batch-loaded (got #{recurrence_rule_queries.size} queries for #{active_count} series)"
  end
end
