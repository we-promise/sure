require "test_helper"

class RecurringTransaction::HistoryBackfillerTest < ActiveSupport::TestCase
  Backfiller = RecurringTransaction::HistoryBackfiller

  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
  end

  test "closes history a real entry anchors and prunes the rest" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY WATER", amount: 80, day_offset: -1)
      # A four-month window (from Apr 10) materializes May/Jun/Jul; entries
      # cover two of them and May is a gap.
      create_entry(amount: 80, date: Date.new(2026, 7, 9), name: "CITY WATER")
      create_entry(amount: 80, date: Date.new(2026, 6, 9), name: "CITY WATER")

      pruned = Backfiller.new(@family, months: 4).run!

      paid = series.recurring_occurrences.paid.pluck(:due_on)
      assert_includes paid, Date.new(2026, 7, 9)
      assert_includes paid, Date.new(2026, 6, 9)
      assert_not_includes series.recurring_occurrences.pluck(:due_on), Date.new(2026, 5, 9),
        "an uncovered past occurrence is deleted, not kept as debt"
      assert_operator pruned, :>=, 1
    end
  end

  test "running twice is byte-identical" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY WATER", amount: 80, day_offset: -1)
      create_entry(amount: 80, date: Date.new(2026, 7, 9), name: "CITY WATER")

      Backfiller.new(@family, months: 3).run!
      state = snapshot(series)

      Backfiller.new(@family, months: 3).run!
      assert_equal state, snapshot(series)
    end
  end

  test "pre-existing allocations are never touched" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY WATER", amount: 80, day_offset: -1)
      RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.new(2026, 6, 1))
      past = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 7, 9))
      allocation = past.allocations.create!(allocated_amount: 80, currency: "USD", source: "user_created")

      Backfiller.new(@family, months: 3).run!

      assert RecurringAllocation.exists?(allocation.id)
      assert RecurringOccurrence.exists?(past.id), "an allocated row survives the prune"
    end
  end

  test "series_scope narrows generation and pruning to the given series" do
    travel_to Date.new(2026, 8, 10) do
      target = create_series(name: "CITY WATER", amount: 80, day_offset: -1)
      other = create_series(name: "CITY GAS", amount: 55, day_offset: -1)
      create_entry(amount: 80, date: Date.new(2026, 7, 9), name: "CITY WATER")

      Backfiller.new(
        @family,
        months: 3,
        series_scope: @family.recurring_transactions.where(id: target.id)
      ).run!

      assert_operator target.recurring_occurrences.where("due_on < ?", Date.new(2026, 8, 1)).count, :>=, 1
      assert_equal 0, other.recurring_occurrences.where("due_on < ?", Date.new(2026, 8, 1)).count,
        "an unscoped series gains no backfilled history"
    end
  end

  private

    def snapshot(series)
      [
        series.recurring_occurrences.order(:due_on).pluck(:due_on, :status),
        RecurringAllocation.joins(:recurring_occurrence)
                           .where(recurring_occurrences: { recurring_transaction_id: series.id })
                           .count
      ]
    end

    def create_series(amount:, day_offset:, name: nil)
      due = Date.current + day_offset

      @family.recurring_transactions.create!(
        name: name,
        account: @account,
        amount: amount,
        currency: "USD",
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: true
      )
    end

    def create_entry(amount:, date:, name:)
      @account.entries.create!(
        date: date,
        amount: amount,
        currency: "USD",
        name: name,
        entryable: Transaction.new
      )
    end
end
