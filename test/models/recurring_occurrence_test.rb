require "test_helper"

class RecurringOccurrenceTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @series = recurring_transactions(:netflix_subscription)
  end

  test "expected amount inherits from the series until overridden" do
    occurrence = create_occurrence
    assert_equal @series.amount, occurrence.resolved_expected_amount

    # A series price edit reaches every open occurrence with zero sweeps.
    @series.update!(amount: 18.99)
    assert_equal 18.99, occurrence.resolved_expected_amount

    occurrence.override_amount!(20)
    assert_equal 20, occurrence.resolved_expected_amount

    occurrence.override_amount!(nil)
    assert_equal 18.99, occurrence.resolved_expected_amount
  end

  test "average strategy resolves through the series variance" do
    @series.update!(amount_strategy: "average", expected_amount_min: 10, expected_amount_max: 20, expected_amount_avg: 15.5)
    occurrence = create_occurrence
    assert_equal 15.5, occurrence.resolved_expected_amount
  end

  test "closing freezes the resolved amount so later series edits cannot rewrite history" do
    occurrence = create_occurrence
    occurrence.skip!

    @series.update!(amount: 99.99)
    assert_equal 15.99, occurrence.reload.expected_amount
    assert_equal 15.99, occurrence.resolved_expected_amount
  end

  test "reopening keeps the frozen amount as an explicit override" do
    occurrence = create_occurrence
    occurrence.close!("paid", source: "user")
    occurrence.reopen!

    assert occurrence.scheduled?
    assert_nil occurrence.closed_at
    assert_equal 15.99, occurrence.expected_amount
  end

  test "derived state walks upcoming, due, overdue with snooze respected" do
    travel_to Date.new(2026, 8, 13) do
      assert_equal :upcoming, create_occurrence(due_on: Date.new(2026, 8, 20), original: Date.new(2026, 8, 20)).derived_state
      assert_equal :due, create_occurrence(due_on: Date.new(2026, 8, 15), original: Date.new(2026, 8, 15)).derived_state
      assert_equal :due, create_occurrence(due_on: Date.new(2026, 8, 11), original: Date.new(2026, 8, 11)).derived_state

      overdue = create_occurrence(due_on: Date.new(2026, 8, 5), original: Date.new(2026, 8, 5))
      assert_equal :overdue, overdue.derived_state

      overdue.snooze!(Date.new(2026, 8, 25))
      assert_equal :upcoming, overdue.derived_state
    end
  end

  test "partial payment is exact-sum, never tolerance" do
    occurrence = create_occurrence
    occurrence.allocations.create!(allocated_amount: 10, currency: "USD", source: "user_created")

    assert occurrence.partially_paid?
    assert_equal 5.99, occurrence.remaining_amount
  end

  test "last strategy resolves to what the previous cycle actually cost" do
    @series.update!(amount_strategy: "last")

    # Expected 15.99, really charged 17.25: inside tolerance, so it closes as
    # actual-replaces-estimate and the frozen expected stays at the estimate.
    settled = create_occurrence(due_on: Date.current - 30, original: Date.current - 30)
    settled.allocations.create!(allocated_amount: 17.25, currency: "USD",
                                state: "confirmed", source: "user_created")
    settled.close!("paid", source: "auto")

    assert_equal 15.99, settled.reload.expected_amount, "the frozen value is the estimate"
    assert_equal 17.25, create_occurrence.resolved_expected_amount,
      "'last' must propose the real charge, not the old estimate"
  end

  test "last strategy ignores a paid cycle that carries no payments" do
    @series.update!(amount_strategy: "last")
    create_occurrence(due_on: Date.current - 30, original: Date.current - 30)
      .close!("paid", source: "user")

    assert_equal 15.99, create_occurrence.resolved_expected_amount
  end

  test "the system never sets missed" do
    occurrence = create_occurrence(due_on: 3.months.ago.to_date, original: 3.months.ago.to_date)
    assert_equal :overdue, occurrence.derived_state

    occurrence.miss!
    assert occurrence.missed?
    assert_equal "user", occurrence.closed_source
  end

  private
    def create_occurrence(due_on: Date.current + 10, original: nil)
      @series.recurring_occurrences.create!(
        family: @family,
        original_due_on: original || due_on,
        due_on: due_on,
        currency: "USD"
      )
    end
end
