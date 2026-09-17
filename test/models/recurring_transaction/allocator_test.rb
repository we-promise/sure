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

  test "a currency mismatch reads as a sentence, not a missing translation" do
    allocation = RecurringAllocation.new(
      recurring_occurrence: @occurrence, state: :confirmed, source: :user_confirmed,
      allocated_amount: 10, currency: "EUR", paid_on: Date.current
    )

    assert_not allocation.valid?
    message = allocation.errors.full_messages_for(:currency).join
    assert_no_match(/translation missing/i, message)
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

  test "a partly allocated cross-currency entry defaults to its leftover" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.1, date: Date.current)
    foreign = @account.entries.create!(
      date: Date.current, amount: 100, currency: "EUR", name: "EU charge",
      entryable: Transaction.new
    )
    @allocator.allocate!(entry: foreign, amount: 55)

    free_date = (Date.current + 2.months).beginning_of_month + 9
    other = @rent.recurring_occurrences.create!(
      family: @family, original_due_on: free_date, due_on: free_date, currency: "USD"
    )
    # 50 EUR of the entry is spoken for, so the default is the 50 EUR
    # leftover converted, not the full 100 the old default reached for.
    allocation = Allocator.new(other).allocate!(entry: foreign)

    assert_equal 55, allocation.allocated_amount
    assert_equal 50, allocation.source_amount
  end

  test "a cross-currency default takes what the occurrence needs, not the whole entry" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.1, date: Date.current)
    @allocator.allocate!(entry: entry_for(1900))
    foreign = @account.entries.create!(
      date: Date.current, amount: 200, currency: "EUR", name: "EU charge",
      entryable: Transaction.new
    )
    allocation = @allocator.allocate!(entry: foreign)

    assert_equal 100, allocation.allocated_amount
    assert @occurrence.reload.paid?
  end

  test "entry deletion nullifies the link but keeps the payment" do
    payment = entry_for(500)
    allocation = @allocator.allocate!(entry: payment)

    payment.destroy!

    allocation.reload
    assert_nil allocation.entry_id
    assert_equal 500, allocation.allocated_amount
  end


  # Without a rate for the entry's date an allocation has no source amount, so
  # it cannot be measured against the transaction. The guard used to skip those
  # entirely, and entry_capacity summed COALESCE(source_amount, allocated_amount)
  # across currencies, so one 100 EUR transaction could pay 150 USD twice and
  # keep going.
  test "an unmeasurable entry cannot be spread across several occurrences" do
    ExchangeRate.delete_all
    entry = foreign_entry(amount: 100, currency: "EUR")
    first_occurrence = usd_occurrence(expected: 150)
    second_occurrence = usd_occurrence(expected: 150, due_on: Date.current + 30)

    RecurringTransaction::Allocator.new(first_occurrence).allocate!(amount: 150, entry: entry)

    assert_raises RecurringTransaction::Allocator::OverAllocationError do
      RecurringTransaction::Allocator.new(second_occurrence).allocate!(amount: 150, entry: entry)
    end

    assert_equal 1, RecurringAllocation.where(entry: entry).count,
      "one judgement call is allowed; an unbounded fan-out is not"
  end

  test "the first unmeasurable allocation is still permitted" do
    ExchangeRate.delete_all
    entry = foreign_entry(amount: 100, currency: "EUR")
    occurrence = usd_occurrence(expected: 150)

    allocation = RecurringTransaction::Allocator.new(occurrence).allocate!(amount: 150, entry: entry)

    assert allocation.persisted?
    assert_nil allocation.source_amount
  end

  # The remainder guard is opt-in and lives INSIDE the occurrence lock,
  # because a caller's pre-lock capacity check is advisory: two concurrent
  # payments can both read the same stale remainder. Sequentially that
  # surfaces as: the second payment sees the first one's allocation.
  test "a capped amount cannot exceed what remains on the cycle" do
    occurrence = usd_occurrence(expected: 100)
    allocator = RecurringTransaction::Allocator.new(occurrence)

    allocator.allocate!(amount: 60, source: "user_created", cap_at_remaining: true)

    error = assert_raises(RecurringTransaction::Allocator::OverAllocationError) do
      allocator.allocate!(amount: 60, source: "user_created", cap_at_remaining: true)
    end
    assert_match(/remaining/, error.message)
    assert_equal 60, occurrence.reload.allocations.sum(:allocated_amount)
  end

  # Exceeding the remainder stays legal for every caller that does not ask
  # for capping: a single settlement above the expected amount is how a price
  # rise gets recorded, and PriceChangeDetector reads exactly those.
  test "an uncapped settlement above the expected amount is still permitted" do
    occurrence = usd_occurrence(expected: 80)

    allocation = RecurringTransaction::Allocator.new(occurrence)
                                                .allocate!(amount: 95, source: "user_created")

    assert allocation.persisted?
    assert_equal 95, occurrence.reload.allocations.sum(:allocated_amount)
  end

  private

    def foreign_entry(amount:, currency:)
      account = accounts(:depository)
      account.entries.create!(
        name: "Foreign charge", date: Date.current, amount: amount,
        currency: currency, entryable: Transaction.new
      )
    end

    def usd_occurrence(expected:, due_on: Date.current)
      series = @family.recurring_transactions.create!(
        name: "Bill #{expected} #{due_on}", account: accounts(:depository),
        amount: expected, currency: "USD", status: "active", bill_type: "bill",
        manual: true, dedup_scope: "bill-#{expected}-#{due_on}",
        expected_day_of_month: due_on.day, last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: due_on
      )
      series.recurring_occurrences.destroy_all
      series.recurring_occurrences.create!(
        family: @family, original_due_on: due_on, due_on: due_on,
        currency: "USD", expected_amount: expected, status: "scheduled"
      )
    end
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
