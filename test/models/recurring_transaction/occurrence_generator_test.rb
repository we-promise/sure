require "test_helper"

class RecurringTransaction::OccurrenceGeneratorTest < ActiveSupport::TestCase
  Generator = RecurringTransaction::OccurrenceGenerator

  def setup
    @family = families(:dylan_family)
    @series = recurring_transactions(:netflix_subscription)
    @series.recurring_occurrences.delete_all
  end

  test "generates the current cycle and the horizon idempotently" do
    travel_to Date.new(2026, 8, 13) do
      created = Generator.new(@series).generate!
      occurrences = @series.recurring_occurrences.order(:due_on)

      # Day-5 monthly bill: the current cycle started Aug 5, so the
      # recently-due occurrence exists alongside the future window.
      assert_equal Date.new(2026, 8, 5), occurrences.first.due_on
      assert_operator occurrences.last.due_on, :<=, Date.new(2026, 11, 13)
      assert_operator created, :>=, 3

      assert_equal 0, Generator.new(@series).generate!, "second run inserts nothing"
    end
  end

  test "the horizon always includes the next occurrence of a slow cadence" do
    travel_to Date.new(2026, 8, 13) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "annual", day_of_month: "1", month_of_year: "3")
      @series.save!

      # insert_all bypasses the association layer, so read back fresh.
      dues = @series.recurring_occurrences.reload.pluck(:due_on)
      assert_includes dues, Date.new(2027, 3, 1), "annual occurrence beyond 90 days must still materialize"
    end
  end

  test "regenerate_future! respects closed and allocated rows" do
    travel_to Date.new(2026, 8, 13) do
      Generator.new(@series).generate!

      paid = @series.recurring_occurrences.find_by!(due_on: Date.new(2026, 9, 5))
      paid.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created")
      future = @series.recurring_occurrences.find_by!(due_on: Date.new(2026, 10, 5))

      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "20")
      @series.save!

      remaining = @series.recurring_occurrences.reload
      assert_includes remaining.map(&:id), paid.id, "allocated rows survive schedule edits"
      assert_not_includes remaining.map(&:id), future.id, "unallocated future rows are rebuilt"
      assert_includes remaining.map(&:due_on), Date.new(2026, 8, 20)
    end
  end

  test "pausing prunes the re-generatable future and resuming rebuilds it" do
    travel_to Date.new(2026, 8, 13) do
      Generator.new(@series).generate!
      assert_operator @series.recurring_occurrences.count, :>, 1

      @series.update!(status: "paused")
      assert_equal 0, @series.recurring_occurrences.where("due_on >= ?", Date.current).count

      @series.update!(status: "active")
      assert_operator @series.recurring_occurrences.where("due_on >= ?", Date.current).count, :>=, 3
    end
  end

  test "a declared bill's first obligation is its anchor, never a fabricated previous cycle" do
    travel_to Date.new(2026, 8, 13) do
      declared = @family.recurring_transactions.create!(
        name: "Declared rent", amount: 2150, currency: "USD",
        expected_day_of_month: 23, anchor_date: Date.new(2026, 8, 23),
        last_occurrence_date: Date.new(2026, 8, 23), next_expected_date: Date.new(2026, 8, 23),
        status: "active", manual: true
      )

      first = declared.recurring_occurrences.reload.order(:due_on).first
      assert_equal Date.new(2026, 8, 23), first.due_on, "no phantom July 23 debt"
    end
  end

  test "suggested series generate nothing" do
    @series.update!(status: "suggested")
    assert_equal 0, Generator.new(@series).generate!.to_i
    assert_empty @series.recurring_occurrences
  end

  test "occurrence identity is the raw date, so weekend adjustment does not fork rows" do
    travel_to Date.new(2026, 8, 1) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "15")
      @series.weekend_adjust = "before"
      @series.save!

      # Aug 15 2026 is a Saturday: due Friday the 14th, identity still the 15th.
      occurrence = @series.recurring_occurrences.find_by!(original_due_on: Date.new(2026, 8, 15))
      assert_equal Date.new(2026, 8, 14), occurrence.due_on

      assert_equal 0, Generator.new(@series).generate!, "adjusted occurrence does not re-insert"
    end
  end
end
