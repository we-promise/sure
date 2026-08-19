require "test_helper"

class RecurringTransaction::PriceChangeDetectorTest < ActiveSupport::TestCase
  Detector = RecurringTransaction::PriceChangeDetector

  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
    @detector = Detector.new(@family)
  end

  test "two consecutive settlements at a new price update an auto series and record the change" do
    series = create_series(amount: 79.99, manual: false)
    settle(series, 1.month.ago.to_date, 94.99)
    settle(series, Date.current, 94.99)

    assert_equal 1, @detector.detect!

    series.reload
    assert_equal 94.99, series.amount
    change = series.recurring_price_changes.sole
    assert_equal 79.99, change.previous_amount
    assert_equal 94.99, change.new_amount
    assert change.recorded_by_detected?
  end

  test "a manual series gets the change recorded but keeps its declared amount" do
    series = create_series(amount: 100, manual: true)
    settle(series, 1.month.ago.to_date, 118)
    settle(series, Date.current, 118)

    @detector.detect!

    series.reload
    assert_equal 100, series.amount, "the user declared it; the user changes it"
    assert_equal 1, series.recurring_price_changes.count
  end

  test "one odd charge is never a price change" do
    series = create_series(amount: 79.99, manual: false)
    settle(series, 1.month.ago.to_date, 79.99)
    settle(series, Date.current, 94.99)

    assert_equal 0, @detector.detect!
    assert_empty series.recurring_price_changes
  end

  test "a pile of partial payments says nothing about price" do
    series = create_series(amount: 2000, manual: true)
    [ 1.month.ago.to_date, Date.current ].each do |due|
      occurrence = series.recurring_occurrences.create!(
        family: @family, original_due_on: due, due_on: due, currency: "USD"
      )
      allocator = RecurringTransaction::Allocator.new(occurrence)
      allocator.allocate!(amount: "1100")
      allocator.allocate!(amount: "1100")
    end

    assert_equal 0, @detector.detect!
  end

  test "detection does not repeat itself" do
    series = create_series(amount: 79.99, manual: false)
    settle(series, 1.month.ago.to_date, 94.99)
    settle(series, Date.current, 94.99)

    assert_equal 1, @detector.detect!
    assert_equal 0, @detector.detect!, "same evidence must not mint a second change"
  end

  test "the recorded change links the settling payment's entry, not a bystander suggestion" do
    series = create_series(amount: 79.99, manual: false)
    settle(series, 1.month.ago.to_date, 94.99)

    newest = series.recurring_occurrences.find_or_create_by!(
      family: @family, original_due_on: Date.current
    ) { |o| o.due_on = Date.current; o.currency = "USD" }
    decoy = @account.entries.create!(
      date: Date.current, amount: 94.99, currency: "USD",
      name: "FIBER INTERNET PENDING", entryable: Transaction.new
    )
    paying_entry = @account.entries.create!(
      date: Date.current, amount: 94.99, currency: "USD",
      name: "FIBER INTERNET", entryable: Transaction.new
    )
    # A suggestion sits on the same occurrence; reading the unordered
    # association's first row could hand the change the decoy's entry.
    RecurringTransaction::Allocator.new(newest).allocate_matched!(
      entry: decoy, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )
    RecurringTransaction::Allocator.new(newest.reload).allocate!(entry: paying_entry, amount: "94.99")
    newest.reload
    RecurringTransaction::Allocator.new(newest).mark_paid! unless newest.paid?

    assert_equal 1, @detector.detect!

    change = series.recurring_price_changes.sole
    assert_equal paying_entry.id, change.entry_id,
      "the entry on the change must be the confirmed settlement's"
  end

  private
    def create_series(amount:, manual:)
      due = Date.current + 20

      @family.recurring_transactions.create!(
        name: "FIBER INTERNET",
        account: @account,
        amount: amount,
        currency: "USD",
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: manual
      )
    end

    def settle(series, due, paid_amount)
      occurrence = series.recurring_occurrences.find_or_create_by!(
        family: @family, original_due_on: due
      ) { |o| o.due_on = due; o.currency = "USD" }

      RecurringTransaction::Allocator.new(occurrence).allocate!(amount: paid_amount.to_s)
      occurrence.reload
      RecurringTransaction::Allocator.new(occurrence).mark_paid! unless occurrence.paid?
      occurrence.reload
    end
end
