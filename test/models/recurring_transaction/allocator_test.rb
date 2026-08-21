require "test_helper"

class RecurringTransaction::AllocatorTest < ActiveSupport::TestCase
  Allocator = RecurringTransaction::Allocator

  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @rent = @family.recurring_transactions.create!(
      account: @account,
      name: "Watson Property",
      amount: 2000,
      currency: "USD",
      expected_day_of_month: 29,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      manual: true
    )
    @occurrence = @rent.recurring_occurrences.order(:due_on).last ||
                  @rent.recurring_occurrences.create!(family: @family,
                                                      original_due_on: (Date.current + 1.month).beginning_of_month + 9,
                                                      due_on: (Date.current + 1.month).beginning_of_month + 9,
                                                      currency: "USD")
    @allocator = Allocator.new(@occurrence)
  end

  test "a price rise does not re-target an occurrence that has already been paid against" do
    @occurrence.update!(expected_amount: nil) # inheriting from the series
    @allocator.allocate!(entry: entry_for(500))

    assert_equal 1500, @occurrence.reload.remaining_amount

    @rent.update!(amount: 2500)

    occurrence = @occurrence.reload
    assert_equal 2000, occurrence.resolved_expected_amount,
      "the $500 was paid against a $2,000 obligation and must stay against it"
    assert_equal 1500, occurrence.remaining_amount
  end

  test "a price rise still updates an open occurrence nobody has paid against" do
    @occurrence.update!(expected_amount: nil)

    @rent.update!(amount: 2500)

    assert_equal 2500, @occurrence.reload.resolved_expected_amount
  end

  test "a suggestion does not pin the amount" do
    @occurrence.update!(expected_amount: nil)
    @allocator.allocate_matched!(entry: entry_for(500), state: "suggested", confidence: 0.7, signals: {})

    @rent.update!(amount: 2500)

    assert_nil @occurrence.reload.expected_amount
    assert_equal 2500, @occurrence.resolved_expected_amount
  end

  test "a partial payment teaches the matcher nothing about tolerance" do
    # $1,625 against $2,000 rent is an installment, not evidence rent varies.
    # It is the only allocation, which is what used to be mistaken for proof.
    @allocator.allocate!(entry: entry_for(1625))

    assert @occurrence.reload.partially_paid?
    assert_nil @rent.reload.matcher_hints["learned_tolerance_pct"]
  end

  test "a single payment that settles the bill above the band does widen tolerance" do
    # $2,200 settles a $2,000 obligation and sits outside the 7.5% band, so the
    # band really was too tight.
    @allocator.allocate!(entry: entry_for(2200))

    assert @occurrence.reload.paid?
    assert_equal 10.0, @rent.reload.matcher_hints["learned_tolerance_pct"]
  end

  test "partial payments accumulate and close only at the exact sum" do
    @allocator.allocate!(entry: entry_for(750))
    @allocator.allocate!(entry: entry_for(500))

    assert @occurrence.reload.partially_paid?
    assert_equal 750, @occurrence.remaining_amount

    @allocator.allocate!(entry: entry_for(750))

    assert @occurrence.reload.paid?
    assert_equal "auto", @occurrence.closed_source
  end

  test "1850 of 2000 stays partially paid, never paid" do
    # The Check Mode regression: tolerance-close must not apply to
    # accumulated partials.
    @allocator.allocate!(entry: entry_for(750))
    @allocator.allocate!(entry: entry_for(500))
    @allocator.allocate!(entry: entry_for(600))

    occurrence = @occurrence.reload
    assert occurrence.scheduled?, "must NOT close"
    assert occurrence.partially_paid?
    assert_equal 150, occurrence.remaining_amount
  end

  test "a single payment within tolerance closes as actual-replaces-estimate" do
    # Expected $2,000 ± 7.5%; one charge of $2,080 IS the bill.
    @allocator.allocate!(entry: entry_for(2080))

    occurrence = @occurrence.reload
    assert occurrence.paid?
    assert_equal "auto", occurrence.closed_source
  end

  test "a single payment below the band stays partial" do
    @allocator.allocate!(entry: entry_for(1500))
    assert @occurrence.reload.partially_paid?
  end

  test "overpayment closes and flags" do
    # The default allocation takes only what the occurrence needs, so an
    # overpay has to be explicit.
    @allocator.allocate!(entry: entry_for(1200), amount: 1200)
    @allocator.allocate!(entry: entry_for(1200), amount: 1200)

    occurrence = @occurrence.reload
    assert occurrence.paid?
    assert occurrence.overpaid?
  end

  test "removing the satisfying allocation reopens an auto-closed occurrence but never a user-closed one" do
    allocation = @allocator.allocate!(entry: entry_for(2000))
    assert @occurrence.reload.paid?

    @allocator.unallocate!(allocation)
    assert @occurrence.reload.scheduled?, "auto-closed reopens"

    @allocator.mark_paid!
    assert @occurrence.reload.paid?
    assert_equal "user", @occurrence.closed_source

    padding = @occurrence.allocations.order(:created_at).last
    @allocator.unallocate!(padding)
    assert @occurrence.reload.paid?, "user-closed never auto-reopens"
  end

  test "mark_paid! settles the remainder without a transaction" do
    @allocator.allocate!(entry: entry_for(537.50))
    @allocator.mark_paid!

    occurrence = @occurrence.reload
    assert occurrence.paid?
    manual = occurrence.allocations.where(entry_id: nil).first
    assert_equal 1462.50, manual.allocated_amount
    assert manual.from_user_created?
  end

  test "one entry can pay several occurrences but never more than itself" do
    lump = entry_for(1612.50)
    # A mid-month date the day-29 series never generates, so this manual
    # row can never collide with the generator's rows regardless of what
    # Date.current is when the suite runs.
    free_date = (Date.current + 2.months).beginning_of_month + 9
    september = @rent.recurring_occurrences.create!(
      family: @family, original_due_on: free_date, due_on: free_date, currency: "USD"
    )

    @allocator.allocate!(entry: lump, amount: 1000)
    Allocator.new(september).allocate!(entry: lump, amount: 612.50)

    assert_raises Allocator::OverAllocationError do
      Allocator.new(september).allocate!(entry: lump, amount: 500)
    end
  end

  test "the same entry cannot be allocated twice to one occurrence" do
    # Partial amounts so the capacity guard passes; the unique index is the
    # backstop this test pins.
    payment = entry_for(500)
    @allocator.allocate!(entry: payment, amount: 200)

    assert_raises ActiveRecord::RecordNotUnique do
      @allocator.allocate!(entry: payment, amount: 100)
    end
  end

  test "default allocation takes what the occurrence needs, not the whole entry" do
    @allocator.allocate!(entry: entry_for(1900))
    big = entry_for(500)
    allocation = @allocator.allocate!(entry: big)

    assert_equal 100, allocation.allocated_amount
    assert @occurrence.reload.paid?
  end

  test "a cross-currency entry without a rate demands an explicit amount" do
    foreign = @account.entries.create!(
      date: Date.current, amount: 100, currency: "EUR", name: "EU charge",
      entryable: Transaction.new
    )

    assert_raises Allocator::MissingRateError do
      @allocator.allocate!(entry: foreign)
    end

    allocation = @allocator.allocate!(entry: foreign, amount: 110)
    assert_equal 110, allocation.allocated_amount
    assert_equal "USD", allocation.currency
    assert_equal "EUR", allocation.source_currency
  end

  test "entry deletion nullifies the link but keeps the payment" do
    payment = entry_for(500)
    allocation = @allocator.allocate!(entry: payment)

    payment.destroy!

    allocation.reload
    assert_nil allocation.entry_id
    assert_equal 500, allocation.allocated_amount
  end

  private
    def entry_for(amount)
      @account.entries.create!(
        date: Date.current,
        amount: amount,
        currency: "USD",
        name: "Watson Property",
        entryable: Transaction.new
      )
    end
end
