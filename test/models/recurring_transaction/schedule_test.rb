require "test_helper"

# Characterization tests for the recurring-transaction date math as it behaves
# today, written BEFORE extracting RecurringTransaction::Schedule. The extraction
# must keep every one of these green without edits; that is the proof of zero
# behavior change. Quirks are asserted deliberately (and called out inline) so a
# later, intentional fix has to change a test to do it.
class RecurringTransaction::ScheduleTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @merchant = merchants(:netflix)
    @account = accounts(:depository)
  end

  # --- RecurringTransaction.calculate_next_expected_date_from_today ---

  test "from_today returns this month's date when the expected day is still ahead" do
    travel_to Date.new(2026, 8, 13) do
      assert_equal Date.new(2026, 8, 20), RecurringTransaction.calculate_next_expected_date_from_today(20)
    end
  end

  test "from_today rolls to next month when the expected day is today" do
    travel_to Date.new(2026, 8, 13) do
      assert_equal Date.new(2026, 9, 13), RecurringTransaction.calculate_next_expected_date_from_today(13)
    end
  end

  test "from_today rolls to next month when the expected day has passed" do
    travel_to Date.new(2026, 8, 13) do
      assert_equal Date.new(2026, 9, 5), RecurringTransaction.calculate_next_expected_date_from_today(5)
    end
  end

  test "from_today handles a day absent from the current month by skipping to next month's real day" do
    # Quirk: on Feb 10 a day-31 bill does not clamp to Feb 28 -- Date.new raises,
    # and the rescue path lands on March 31. February is skipped entirely.
    travel_to Date.new(2026, 2, 10) do
      assert_equal Date.new(2026, 3, 31), RecurringTransaction.calculate_next_expected_date_from_today(31)
    end
  end

  # --- RecurringTransaction.calculate_next_expected_date_for ---

  test "for clamps to end of month when the day does not exist" do
    assert_equal Date.new(2026, 2, 28), RecurringTransaction.calculate_next_expected_date_for(Date.new(2026, 1, 31), 31)
  end

  test "for clamps to Feb 29 in a leap year" do
    assert_equal Date.new(2024, 2, 29), RecurringTransaction.calculate_next_expected_date_for(Date.new(2024, 1, 15), 31)
  end

  test "for lands on the expected day in the month after from_date" do
    assert_equal Date.new(2026, 9, 15), RecurringTransaction.calculate_next_expected_date_for(Date.new(2026, 8, 10), 15)
  end

  # --- RecurringTransaction#calculate_next_expected_date ---

  test "instance next date always jumps to the month after the last occurrence" do
    # Quirk (the early-payer bug): rent due on the 29th, last paid Aug 6, reads
    # as due Sep 29 -- the Aug 29 occurrence still ahead is skipped. Kept as-is
    # here; the write-path fix lands with the occurrence work.
    recurring = build_recurring(expected_day_of_month: 29, last_occurrence_date: Date.new(2026, 8, 6))
    assert_equal Date.new(2026, 9, 29), recurring.calculate_next_expected_date
  end

  test "instance next date defaults to counting from last_occurrence_date" do
    recurring = build_recurring(expected_day_of_month: 15, last_occurrence_date: Date.new(2026, 7, 15))
    assert_equal Date.new(2026, 8, 15), recurring.calculate_next_expected_date
    assert_equal Date.new(2026, 10, 15), recurring.calculate_next_expected_date(Date.new(2026, 9, 20))
  end

  test "instance next date clamps to end of month" do
    recurring = build_recurring(expected_day_of_month: 31, last_occurrence_date: Date.new(2026, 1, 15))
    assert_equal Date.new(2026, 2, 28), recurring.calculate_next_expected_date
  end

  # --- Identifier's private copy stays behavior-identical until it delegates ---

  test "identifier next date matches the model's math" do
    identifier = RecurringTransaction::Identifier.new(@family)
    assert_equal Date.new(2026, 2, 28), identifier.send(:calculate_next_expected_date, Date.new(2026, 1, 15), 31)
    assert_equal Date.new(2026, 9, 29), identifier.send(:calculate_next_expected_date, Date.new(2026, 8, 6), 29)
  end

  # --- day_of_month_scope: linear window, no wraparound, no clamping ---

  test "matching window for day 1 is linear and does not wrap to month end" do
    # Quirk: the SQL window for day 1 is [1, 3]. An entry on the 30th is 2 days
    # away on the calendar circle but does NOT match, unlike the Identifier's
    # circular matcher. This inconsistency is fixed in a follow-up commit.
    recurring = create_recurring(expected_day_of_month: 1)
    in_window = create_matching_entry(recurring, date: Date.new(2026, 7, 2))
    wrapped = create_matching_entry(recurring, date: Date.new(2026, 7, 30))

    matches = recurring.matching_transactions
    assert_includes matches, in_window
    assert_not_includes matches, wrapped
  end

  test "matching window for day 31 tolerates only earlier days" do
    recurring = create_recurring(expected_day_of_month: 31)
    in_window = create_matching_entry(recurring, date: Date.new(2026, 7, 29))
    outside = create_matching_entry(recurring, date: Date.new(2026, 7, 28))

    matches = recurring.matching_transactions
    assert_includes matches, in_window
    assert_not_includes matches, outside
  end

  private
    def build_recurring(**overrides)
      @family.recurring_transactions.build(
        account: @account,
        merchant: @merchant,
        amount: 29.99,
        currency: "USD",
        expected_day_of_month: 15,
        last_occurrence_date: Date.new(2026, 7, 15),
        next_expected_date: Date.new(2026, 8, 15),
        status: "active",
        **overrides
      )
    end

    def create_recurring(**overrides)
      recurring = build_recurring(**overrides)
      recurring.save!
      recurring
    end

    def create_matching_entry(recurring, date:)
      @account.entries.create!(
        date: date,
        amount: recurring.amount,
        currency: recurring.currency,
        name: "Netflix charge",
        entryable: Transaction.new(merchant_id: recurring.merchant_id)
      )
    end
end
