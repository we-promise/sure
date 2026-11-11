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

  test "a variable-amount bill with a bank reference keeps its history instead of being pruned" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY WATER", amount: 80, day_offset: -1)
      series.update!(bank_reference: "VN 4711")
      create_entry(amount: 131.40, date: Date.new(2026, 7, 9), name: "CITY WATER", notes: "VN 4711 Abschlag")
      create_entry(amount: 52.10, date: Date.new(2026, 6, 9), name: "CITY WATER", notes: "VN 4711 Abschlag")

      Backfiller.new(@family, months: 4).run!

      assert_includes series.recurring_occurrences.paid.pluck(:due_on), Date.new(2026, 7, 9)
      # Underpaid, so linked but not closed; the point is that it is not pruned.
      june = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 6, 9))
      assert_equal 52.10, june.allocations.sole.allocated_amount.to_f
    end
  end

  # Live case: a quarterly insurance whose premium dropped 15% for four quarters
  # and then came back, every payment carrying the reference.
  test "a deviating payment identified by the reference is linked and its occurrence is never pruned" do
    travel_to Date.new(2026, 11, 11) do
      series = create_series(name: "Home Insurance", amount: 400.00, day_offset: 0)
      series.update!(bank_reference: "POL-04-123456")
      series.update_columns(expected_day_of_month: 12, anchor_date: Date.new(2025, 1, 12))
      RecurringTransaction::FrequencyPreset.apply(series, preset: "quarterly", day_of_month: 12, month_of_year: 1)
      series.save!

      payments = { Date.new(2025, 4, 23) => 340.00, Date.new(2025, 7, 14) => 340.00, Date.new(2025, 10, 13) => 340.00,
                   Date.new(2026, 1, 12) => 340.00, Date.new(2026, 4, 13) => 400.00, Date.new(2026, 7, 13) => 400.00,
                   Date.new(2026, 10, 12) => 400.00 }
      entries = payments.map { |date, amount| create_entry(amount: amount, date: date, name: "Example Insurer", notes: "POL-04-123456 Beitrag") }

      Backfiller.new(@family, months: 24).run!

      assert_equal 7, RecurringAllocation.where(entry_id: entries.map(&:id)).count
      assert_includes series.recurring_occurrences.pluck(:due_on), Date.new(2026, 1, 12)
      assert_equal 7, series.recurring_occurrences.paid.count,
        "a payment the reference identified settles its quarter whatever its amount"
      assert_equal 340.00, series.recurring_occurrences.find_by!(due_on: Date.new(2026, 1, 12)).allocations.sole.allocated_amount.to_f
    end
  end

  test "two reference payments around one due date both link to that occurrence" do
    travel_to Date.new(2026, 11, 11) do
      series = create_series(name: "Example Energy", amount: 150, day_offset: -1)
      series.update!(bank_reference: "Example")
      RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.new(2026, 5, 1))
      # Due on the 10th: both payments are nearest to the July occurrence.
      first = create_entry(amount: 160.00, date: Date.new(2026, 7, 9), name: "Example Energy", notes: "Example Abschlag")
      second = create_entry(amount: 140.00, date: Date.new(2026, 7, 12), name: "Example Energy", notes: "Example Abschlag")

      Backfiller.new(@family, months: 8).run!

      allocations = RecurringAllocation.where(entry_id: [ first.id, second.id ])
      assert_equal 2, allocations.count, "neither payment of the cycle may be dropped"
      assert_equal 1, allocations.distinct.count(:recurring_occurrence_id)
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

    def create_entry(amount:, date:, name:, notes: nil)
      @account.entries.create!(
        date: date,
        notes: notes,
        amount: amount,
        currency: "USD",
        name: name,
        entryable: Transaction.new
      )
    end
end
