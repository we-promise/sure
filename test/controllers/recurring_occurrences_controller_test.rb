require "test_helper"

class RecurringOccurrencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
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

  # Resolving a payment is the ACT surface, so it owns the drawer slot -- the
  # same one transactions, trades and transfers use. The bill's own story moved
  # to its own page, so nothing competes for it.
  test "show renders the occurrence dialog in a single drawer frame" do
    get recurring_occurrence_url(@occurrence), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_equal 1, response.body.scan(/<turbo-frame[^>]*id="drawer"/).size
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

    get recurring_occurrence_url(@occurrence), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match exact.name, response.body,
      "the transaction matching the bill amount must survive the fifteen-row cut"
  end

  # The mission's own example. The picker ranked by amount distance and nothing
  # else, so a $6.44 Twitch charge scored exactly as well as the $6.44 7-Eleven
  # charge for a 7-Eleven bill. It now asks the matcher, whose identity filter
  # rules the others out entirely rather than merely ranking them lower.
  test "the suggested payment is the one the matcher would have picked" do
    seven_eleven = merchants(:netflix)
    series = @family.recurring_transactions.create!(
      name: "7-Eleven Gold Pass", merchant: seven_eleven, account: accounts(:depository),
      amount: 6.44, currency: "USD", expected_day_of_month: Date.current.day,
      anchor_date: Date.current, last_occurrence_date: Date.current,
      next_expected_date: Date.current, status: "active", manual: true,
      dedup_scope: "gold-pass"
    )
    occurrence = series.recurring_occurrences.order(:due_on).first

    match = accounts(:depository).entries.create!(
      date: occurrence.due_on, amount: 6.44, currency: "USD",
      name: "7-ELEVEN GOLD PASS TM", entryable: Transaction.new(merchant: seven_eleven)
    )
    decoys = [ "Twitch", "Grok", "Steam" ].map do |name|
      accounts(:depository).entries.create!(
        date: occurrence.due_on, amount: 6.44, currency: "USD",
        name: "#{name} subscription", entryable: Transaction.new
      )
    end

    get recurring_occurrence_url(occurrence), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success

    ranked = @controller.view_assigns["ranked_candidates"]
    assert_equal [ match.id ], ranked.map { |entry, _| entry.id },
      "only the 7-Eleven charge belongs to a 7-Eleven bill"

    fallback = @controller.view_assigns["other_entries"].map(&:id)
    decoys.each { |decoy| assert_includes fallback, decoy.id, "unrelated charges stay browsable, just not suggested" }

    # And the reasons are the matcher's own, not a percentage.
    assert_match I18n.t("bills.match.same_merchant"), response.body
    assert_match I18n.t("bills.match.exact_amount"), response.body
  end

  # Corrections are permanently sticky in the matcher. The picker never checked
  # the rejection table, so a transaction the user had already dismissed could
  # come straight back to the top of the list.
  test "a rejected pairing never returns as a suggestion" do
    series = @family.recurring_transactions.create!(
      name: "CITY WATER", account: accounts(:depository), amount: 80, currency: "USD",
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true
    )
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = accounts(:depository).entries.create!(
      date: occurrence.due_on, amount: 80, currency: "USD",
      name: "CITY WATER", entryable: Transaction.new
    )

    get recurring_occurrence_url(occurrence), headers: { "Turbo-Frame" => "drawer" }
    assert_equal [ entry.id ], @controller.view_assigns["ranked_candidates"].map { |candidate, _| candidate.id }

    RecurringMatchRejection.create!(recurring_transaction: series, entry: entry)

    get recurring_occurrence_url(occurrence), headers: { "Turbo-Frame" => "drawer" }
    assert_empty @controller.view_assigns["ranked_candidates"]
  end

  # One transaction can legitimately pay more than one bill, which is why the
  # Allocator guards capacity at write time rather than at read time. Excluding
  # every entry that already has a confirmed allocation would have quietly
  # deleted split payments from the picker.
  test "an entry already allocated to another bill is still offered here" do
    first, second = [ "a", "b" ].map do |scope|
      @family.recurring_transactions.create!(
        name: "WATSON PROPERTY", account: accounts(:depository), amount: 500, currency: "USD",
        expected_day_of_month: Date.current.day, anchor_date: Date.current,
        last_occurrence_date: Date.current, next_expected_date: Date.current,
        status: "active", manual: true, dedup_scope: scope
      ).recurring_occurrences.order(:due_on).first
    end

    entry = accounts(:depository).entries.create!(
      date: first.due_on, amount: 500, currency: "USD",
      name: "WATSON PROPERTY", entryable: Transaction.new
    )
    RecurringTransaction::Allocator.new(first).allocate!(entry: entry, amount: 200)

    get recurring_occurrence_url(second), headers: { "Turbo-Frame" => "drawer" }

    assert_includes @controller.view_assigns["ranked_candidates"].map { |candidate, _| candidate.id }, entry.id,
      "the rest of that charge can still pay another bill; over-allocation is refused when it is written"
  end

  test "searching looks past the date window" do
    old = accounts(:depository).entries.create!(
      date: @occurrence.due_on - 300, amount: 15.99, currency: "USD",
      name: "Ancient Netflix charge", entryable: Transaction.new
    )

    get recurring_occurrence_url(@occurrence), headers: { "Turbo-Frame" => "drawer" }
    assert_no_match old.name, response.body, "outside the window it is not offered by default"

    get recurring_occurrence_url(@occurrence, q: "Ancient"), headers: { "Turbo-Frame" => "drawer" }
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

  # until[]=... makes params.require(:until) an Array, which Date.parse
  # rejects with TypeError rather than ArgumentError. Same user mistake, same
  # invalid-date redirect; never a 500.
  test "a non-scalar until parameter is an invalid date, not a 500" do
    patch snooze_recurring_occurrence_url(@occurrence), params: { until: [ (Date.current + 12).iso8601 ] }

    assert_response :redirect
    assert_nil @occurrence.reload.snoozed_until
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
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

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

  test "the drawer redirects when the family has turned recurring transactions off" do
    @family.update!(recurring_transactions_disabled: true)

    get recurring_occurrence_url(@occurrence)

    assert_redirected_to root_path
  end

  # Sharing is per account. An accountless bill is visible family-wide, but
  # its candidate list must still show only entries from accounts the viewer
  # can reach, or the drawer leaks names and amounts from unshared accounts.
  test "an accountless bill's candidates exclude entries from unshared accounts" do
    accountless = @family.recurring_transactions.create!(
      name: "Water Utility", amount: 60, currency: "USD",
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true
    )
    occurrence = accountless.recurring_occurrences.order(:due_on).first

    hidden = accounts(:investment).entries.create!(
      date: occurrence.due_on, amount: 60, currency: "USD",
      name: "Broker service fee", entryable: Transaction.new
    )
    visible = accounts(:depository).entries.create!(
      date: occurrence.due_on, amount: 60, currency: "USD",
      name: "Shared checking charge", entryable: Transaction.new
    )

    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member
    get recurring_occurrence_url(occurrence), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_no_match hidden.name, response.body,
      "an entry on an account never shared with the viewer must not render"
    assert_match visible.name, response.body,
      "positive control: the same-shaped entry on a shared account must render"
  end

  # credit_card is shared read-only with family_member in the fixtures; a
  # read-only share can look at the bill but never move its payment state.
  test "a read-only account share cannot mutate an occurrence" do
    occurrence = credit_card_occurrence

    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    post mark_paid_recurring_occurrence_url(occurrence)
    assert_response :not_found
    assert occurrence.reload.scheduled?, "a read-only share must not settle the bill"

    post skip_recurring_occurrence_url(occurrence)
    assert_response :not_found

    patch override_amount_recurring_occurrence_url(occurrence, amount: "1")
    assert_response :not_found
    assert_nil occurrence.reload.expected_amount

    get recurring_occurrence_url(occurrence), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success, "reading the shared bill stays allowed"
  end

  test "the account owner still settles the same occurrence" do
    occurrence = credit_card_occurrence

    post mark_paid_recurring_occurrence_url(occurrence)

    assert occurrence.reload.paid?
  end

  private
    def credit_card_occurrence
      series = @family.recurring_transactions.create!(
        name: "Card Annual Fee", account: accounts(:credit_card), amount: 95,
        currency: "USD", expected_day_of_month: Date.current.day,
        anchor_date: Date.current, last_occurrence_date: Date.current,
        next_expected_date: Date.current, status: "active", manual: true
      )
      series.recurring_occurrences.order(:due_on).first
    end
end
