require "test_helper"

class RecurringOccurrencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @series = recurring_transactions(:netflix_subscription)
    @occurrence = @series.recurring_occurrences.create!(
      family: @family,
      original_due_on: Date.current + 5,
      due_on: Date.current + 5,
      currency: "USD"
    )
    ensure_tailwind_build
  end

  test "show renders the occurrence dialog in a single modal frame" do
    get recurring_occurrence_url(@occurrence), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_equal 1, response.body.scan(/<turbo-frame[^>]*id="modal"/).size
  end

  # The dialog used to list the fifteen most RECENT transactions in the window.
  # On a real bill that hid every plausible match behind unrelated larger
  # charges, so the exact payment was invisible.
  test "the transaction list leads with the closest amount, not the most recent" do
    # Older than every distractor, so date order pushes it past the fifteen-row
    # cut. Everything sits in the past, because the window is clipped at today.
    exact = accounts(:depository).entries.create!(
      date: @occurrence.due_on - 35, amount: 15.99, currency: "USD",
      name: "Netflix charge", entryable: Transaction.new
    )
    20.times do |i|
      accounts(:depository).entries.create!(
        date: @occurrence.due_on - 6 - i, amount: 500 + i, currency: "USD",
        name: "Unrelated big charge #{i}", entryable: Transaction.new
      )
    end

    get recurring_occurrence_url(@occurrence), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match exact.name, response.body,
      "the transaction matching the bill amount must survive the fifteen-row cut"
  end

  test "searching looks past the date window" do
    old = accounts(:depository).entries.create!(
      date: @occurrence.due_on - 300, amount: 15.99, currency: "USD",
      name: "Ancient Netflix charge", entryable: Transaction.new
    )

    get recurring_occurrence_url(@occurrence), headers: { "Turbo-Frame" => "modal" }
    assert_no_match old.name, response.body, "outside the window it is not offered by default"

    get recurring_occurrence_url(@occurrence, q: "Ancient"), headers: { "Turbo-Frame" => "modal" }
    assert_match old.name, response.body, "a search must be able to reach it"
  end

  test "mark_paid settles the occurrence" do
    post mark_paid_recurring_occurrence_url(@occurrence)

    assert_redirected_to bills_url
    @occurrence.reload
    assert @occurrence.paid?
    assert_equal "user", @occurrence.closed_source
    assert_equal @occurrence.expected_amount, @occurrence.allocations.sum(:allocated_amount)
  end

  test "skip and reopen round trip" do
    post skip_recurring_occurrence_url(@occurrence)
    assert @occurrence.reload.skipped?

    post reopen_recurring_occurrence_url(@occurrence)
    assert @occurrence.reload.scheduled?
  end

  test "snooze postpones the effective due date" do
    patch snooze_recurring_occurrence_url(@occurrence, until: (Date.current + 12).iso8601)

    assert_equal Date.current + 12, @occurrence.reload.snoozed_until
  end

  test "override amount sets and clears the per-occurrence expectation" do
    patch override_amount_recurring_occurrence_url(@occurrence, amount: "42.50")
    assert_equal 42.50, @occurrence.reload.expected_amount

    patch override_amount_recurring_occurrence_url(@occurrence, amount: "")
    assert_nil @occurrence.reload.expected_amount
  end

  test "another family's occurrence is unreachable" do
    other_family = families(:empty)
    other_series = other_family.recurring_transactions.create!(
      name: "Foreign bill", amount: 10, currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: Date.current, next_expected_date: 1.month.from_now.to_date,
      status: "active", manual: true
    )
    foreign = other_series.recurring_occurrences.order(:due_on).first ||
              other_series.recurring_occurrences.create!(
                family: other_family, original_due_on: Date.current,
                due_on: Date.current, currency: "USD"
              )

    get recurring_occurrence_url(foreign)
    assert_response :not_found
  end

  test "allocating an entry applies its amount toward the occurrence" do
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 10, currency: "USD", name: "Netflix charge",
      entryable: Transaction.new(merchant: merchants(:netflix))
    )

    post recurring_occurrence_allocations_url(@occurrence, entry_id: entry.id)

    allocation = @occurrence.allocations.sole
    assert_equal entry.id, allocation.entry_id
    assert_equal 10, allocation.allocated_amount
    assert @occurrence.reload.partially_paid?
  end

  test "a custom amount records an entry-less payment" do
    post recurring_occurrence_allocations_url(@occurrence), params: { amount: "5.00" }

    allocation = @occurrence.allocations.sole
    assert_nil allocation.entry_id
    assert allocation.from_user_created?
    assert_equal 5, allocation.allocated_amount
  end

  test "over-allocating an entry is refused with an explanation" do
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 10, currency: "USD", name: "Netflix charge",
      entryable: Transaction.new(merchant: merchants(:netflix))
    )

    post recurring_occurrence_allocations_url(@occurrence, entry_id: entry.id), params: { amount: "25" }

    assert_equal 0, @occurrence.allocations.count
    assert_equal I18n.t("recurring_allocations.over_allocation"), flash[:alert]
  end

  # Sharing is per account. A member with no share on the brokerage must not be
  # able to settle a bill with a transaction from it, which would both spend an
  # obligation against money they cannot see and echo the charge back to them.
  test "a member cannot pay a bill with a transaction from an account they were never given" do
    hidden = accounts(:investment).entries.create!(
      date: Date.current, amount: 15.99, currency: "USD", name: "PRIVATE BROKERAGE FEE",
      entryable: Transaction.new
    )
    sign_in users(:family_member)

    post recurring_occurrence_allocations_url(@occurrence, entry_id: hidden.id), params: { amount: "15.99" }

    assert_response :not_found
    assert_equal 0, @occurrence.reload.allocations.count
  end

  test "confirming and rejecting suggestions from the queue" do
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 15.99, currency: "USD", name: "Netflix charge",
      entryable: Transaction.new(merchant: merchants(:netflix))
    )
    suggestion = RecurringTransaction::Allocator.new(@occurrence).allocate_matched!(
      entry: entry, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )

    post confirm_recurring_allocation_url(suggestion)
    assert suggestion.reload.allocation_confirmed?
    assert @occurrence.reload.paid?

    delete recurring_allocation_url(suggestion)
    other = RecurringTransaction::Allocator.new(@occurrence.reload).allocate_matched!(
      entry: entry, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )
    post reject_recurring_allocation_url(other)

    assert_not RecurringAllocation.exists?(other.id)
    assert RecurringMatchRejection.exists?(recurring_transaction: @series, entry: entry)
  end

  test "unlinking a payment reopens an auto-closed occurrence" do
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 15.99, currency: "USD", name: "Netflix charge",
      entryable: Transaction.new(merchant: merchants(:netflix))
    )
    post recurring_occurrence_allocations_url(@occurrence, entry_id: entry.id)
    assert @occurrence.reload.paid?

    delete recurring_allocation_url(@occurrence.allocations.sole)

    assert @occurrence.reload.scheduled?
    assert_equal 0, @occurrence.allocations.count
  end
end
