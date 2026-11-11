require "test_helper"

class RecurringTransaction::MatcherTest < ActiveSupport::TestCase
  Matcher = RecurringTransaction::Matcher

  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
    @matcher = Matcher.new(@family)
  end

  # Candidate collection excludes entries that already have a CONFIRMED
  # allocation, not a suggested one, so an unreviewed suggestion leaves its
  # charge eligible. With two series competing for it, a second run could stack
  # a second allocation on the same charge. What stops it is that the first
  # suggestion has already spoken for the entry's whole amount.
  test "repeat runs never stack a second allocation on one charge" do
    create_series(name: "Streaming Service", amount: 15.99, day_offset: 0, dedup_scope: "a")
    create_series(name: "Streaming Service", amount: 15.99, day_offset: 0, dedup_scope: "b")
    entry = create_entry(amount: 15.99, date: Date.current, name: "Streaming Service")

    3.times { Matcher.new(@family).run! }

    allocations = RecurringAllocation.where(entry_id: entry.id)
    assert_equal 1, allocations.count,
      "one charge must not fund two bills just because the first link is unreviewed"
    assert_equal 15.99, allocations.sum(:allocated_amount).to_f
  end

  test "a merchant charge near the expected amount auto-links and settles the bill" do
    # The mission's own example: Comcast expected at $119.99, charged $121.74.
    series = create_series(name: nil, merchant: merchants(:netflix), amount: 119.99, day_offset: 2)
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 121.74, date: Date.current, merchant: merchants(:netflix))

    assert_equal 1, @matcher.run!

    allocation = occurrence.allocations.sole
    assert allocation.allocation_confirmed?
    assert allocation.from_auto_matched?
    assert_equal entry.id, allocation.entry_id
    assert_operator allocation.match_confidence, :>=, 0.85
    assert allocation.match_signals.key?("merchant")
    assert occurrence.reload.paid?, "single in-tolerance charge IS the bill"
  end

  test "a weaker match lands in the review queue, not on the bill" do
    # A week overdue, paid today at the edge of the amount band: plausible,
    # not certain.
    series = create_series(name: "CITY WATER", amount: 80, day_offset: -7)
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 85.50, date: Date.current, name: "CITY WATER")

    @matcher.run!

    allocation = occurrence.allocations.sole
    assert allocation.allocation_suggested?
    assert occurrence.reload.scheduled?, "suggestions never move paid state"
  end

  test "two look-alike bills competing for one charge demote to suggestions" do
    twin_a = create_series(name: "GYM", amount: 40, day_offset: -3)
    twin_b = create_series(name: "GYM", amount: 40, day_offset: -3, dedup_scope: "second")
    create_entry(amount: 40, date: Date.current - 3, name: "GYM")

    @matcher.run!

    states = (twin_a.recurring_occurrences.order(:due_on).first.allocations.to_a +
              twin_b.recurring_occurrences.order(:due_on).first.allocations.to_a).map(&:state)
    assert_equal [ "suggested" ], states.uniq
    assert_equal 1, states.size, "one entry is proposed once, to the better candidate"
  end

  test "a rejected pair is never suggested again" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: -7)
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 85.50, date: Date.current, name: "CITY WATER")

    @matcher.run!
    suggestion = occurrence.allocations.sole
    RecurringTransaction::Allocator.new(occurrence).reject_suggestion!(suggestion)

    assert_equal 0, @matcher.run!
    assert_equal 0, occurrence.reload.allocations.count
  end

  test "a pending charge is suggested at most, never auto-linked" do
    series = create_series(name: nil, merchant: merchants(:netflix), amount: 119.99, day_offset: 1)
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 119.99, date: Date.current, merchant: merchants(:netflix),
                 extra: { "simplefin" => { "pending" => true } })

    @matcher.run!

    assert occurrence.allocations.sole.allocation_suggested?
  end

  # The payment review queue is where suggestions land, and income review has
  # no home there: a paycheck is not a bill anyone needs to approve paying.
  test "an income series never suggests, while the same shape on a bill does" do
    income = create_series(name: "ACME PAYROLL", amount: -1840, day_offset: -7, bill_type: "income")
    bill = create_series(name: "CITY WATER", amount: 80, day_offset: -7)
    create_entry(amount: -1900, date: Date.current, name: "ACME PAYROLL")
    create_entry(amount: 85.50, date: Date.current, name: "CITY WATER")

    @matcher.run!

    assert_equal 0, income.recurring_occurrences.order(:due_on).first.allocations.count,
      "a near-miss deposit must not queue income for payment review"
    assert bill.recurring_occurrences.order(:due_on).first.allocations.sole.allocation_suggested?,
      "the identical near-miss on a bill still suggests"
  end

  test "an exact income match still auto-links and closes the payday" do
    income = create_series(name: "ACME PAYROLL", amount: -1840, day_offset: 0, bill_type: "income")
    occurrence = income.recurring_occurrences.order(:due_on).first
    create_entry(amount: -1840, date: Date.current, name: "ACME PAYROLL")

    assert_equal 1, @matcher.run!

    assert occurrence.allocations.sole.allocation_confirmed?
    assert occurrence.reload.paid?, "the exact tier is what advances the paycheck planner"
  end

  test "weekly windows clamp so one payment cannot satisfy two weeks" do
    series = create_series(name: "CLEANER", amount: 100, day_offset: 0, preset: "weekly")
    occurrences = series.recurring_occurrences.order(:due_on).limit(2).to_a
    entry = create_entry(amount: 100, date: occurrences.first.due_on, name: "CLEANER")

    @matcher.run!

    linked = RecurringAllocation.where(entry: entry)
    assert_equal 1, linked.count
    assert_equal occurrences.first.id, linked.sole.recurring_occurrence_id
  end

  test "an overdue occurrence stays matchable, and a very late payment queues for review" do
    series = create_series(name: "OLD RENT", amount: 500, day_offset: -20)
    occurrence = series.recurring_occurrences.order(:due_on).first
    assert_equal :overdue, occurrence.derived_state

    create_entry(amount: 500, date: Date.current, name: "OLD RENT")

    @matcher.run!

    # Three weeks of date distance drags an otherwise perfect match below the
    # auto-link bar on purpose: suggest, never silently guess. One click
    # settles it.
    suggestion = occurrence.allocations.sole
    assert suggestion.allocation_suggested?

    RecurringTransaction::Allocator.new(occurrence).confirm_suggestion!(suggestion)
    assert occurrence.reload.paid?
  end

  test "a months-deep backlog matches each payment to its own occurrence" do
    # The Curbside bug: every overdue occurrence's window reaches today, so
    # without nearest-occurrence assignment each exact payment gains
    # same-series runner-ups and demotes to a discarded suggestion.
    series = create_series(name: "CURBSIDE CUTS & SHAVE", amount: 150, day_offset: -19)
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 100)

    past = series.recurring_occurrences.where("due_on <= ?", Date.current).order(:due_on).to_a
    assert_operator past.size, :>=, 3
    past.each { |occurrence| create_entry(amount: 150, date: occurrence.due_on, name: "CURBSIDE CUTS & SHAVE") }

    @matcher.run_backfill!

    past.each do |occurrence|
      assert occurrence.reload.paid?, "#{occurrence.due_on} must close against its own payment"
      assert_equal occurrence.due_on, occurrence.allocations.sole.paid_on
    end
  end

  # Pausing keeps the open leftover, and a late payment must still reach it:
  # the window of an overdue leftover runs to today, paused or not.
  test "a late payment still matches a paused bill's overdue leftover" do
    series = create_series(name: "POWER CO", amount: 60, day_offset: -20)
    occurrence = series.recurring_occurrences.order(:due_on).first
    series.mark_inactive!
    assert_not occurrence.overdue?
    entry = create_entry(amount: 60, date: Date.current, name: "POWER CO")

    @matcher.run!

    assert_equal entry, occurrence.allocations.sole.entry
  end

  test "backfill mode writes confirmed history only, never suggestions" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: -7)
    exact_series = create_series(name: "POWER CO", amount: 60, day_offset: 2)
    create_entry(amount: 85.50, date: Date.current, name: "CITY WATER")
    create_entry(amount: 60, date: Date.current, name: "POWER CO")

    @matcher.run_backfill!

    assert_equal 0, series.recurring_occurrences.order(:due_on).first.allocations.count
    assert exact_series.recurring_occurrences.order(:due_on).first.allocations.sole.allocation_confirmed?
  end

  test "repair re-attaches an allocation whose entry was replaced under it" do
    series = create_series(name: "POWER CO", amount: 60, day_offset: 2)
    occurrence = series.recurring_occurrences.order(:due_on).first
    original = create_entry(amount: 60, date: Date.current, name: "POWER CO")
    @matcher.run!
    allocation = occurrence.allocations.sole

    original.destroy!
    assert_nil allocation.reload.entry_id

    replacement = create_entry(amount: 60, date: allocation.paid_on, name: "POWER CO POSTED")
    @matcher.repair_orphans!

    assert_equal replacement.id, allocation.reload.entry_id
  end

  test "repair re-attaches a recurring transfer's payment by its account pair, not its name" do
    series = create_series(name: "Payment to Loan", amount: 500, day_offset: 0, destination: accounts(:loan))
    occurrence = series.recurring_occurrences.order(:due_on).first
    original = create_transfer(amount: 500, date: Date.current, to: accounts(:loan), name: "LOAN DD 1234")
    @matcher.run!
    allocation = occurrence.allocations.sole

    original.destroy!
    assert_nil allocation.reload.entry_id

    create_transfer(amount: 500, date: allocation.paid_on, to: accounts(:credit_card), name: "LOAN DD 1234")
    replacement = create_transfer(amount: 500, date: allocation.paid_on, to: accounts(:loan), name: "REF 998877")
    Matcher.new(@family).repair_orphans!

    assert_equal replacement.id, allocation.reload.entry_id
  end

  test "candidate collection looks up no transfer per ordinary charge" do
    create_series(name: "Payment to Loan", amount: 500, day_offset: 0, destination: accounts(:loan))
    create_transfer(amount: 500, date: Date.current, to: accounts(:loan))
    3.times { |i| create_entry(amount: 500, date: Date.current - i, name: "charge #{i}") }

    lookups = 0
    count_lookups = ->(*, payload) { lookups += 1 if payload[:sql].match?(/FROM "transfers".*LIMIT/m) }
    ActiveSupport::Notifications.subscribed(count_lookups, "sql.active_record") { @matcher.run! }

    assert_equal 0, lookups, "the batch preload already answers every entry in the window"
  end

  test "manually attaching an alien-named entry teaches an alias" do
    series = create_series(name: "Watson Property", amount: 2150, day_offset: 5)
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 2150, date: Date.current + 4, name: "WPM LLC WEB PMT")

    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: entry)

    assert_includes series.reload.matcher_hints["name_aliases"], "WPM LLC WEB PMT"
  end

  test "a single out-of-band settlement widens the learned tolerance; a partial teaches nothing" do
    series = create_series(name: "POWER CO", amount: 100, day_offset: 5)
    occurrence = series.recurring_occurrences.order(:due_on).first
    settlement = create_entry(amount: 118, date: Date.current + 4, name: "POWER CO")
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: settlement)
    assert_in_delta 18.0, series.reload.matcher_hints["learned_tolerance_pct"], 0.1

    rent = create_series(name: "BIG RENT", amount: 2150, day_offset: 5)
    rent_occurrence = rent.recurring_occurrences.order(:due_on).first
    partial = create_entry(amount: 537.50, date: Date.current + 4, name: "BIG RENT")
    RecurringTransaction::Allocator.new(rent_occurrence).allocate!(entry: partial)

    assert_nil rent.reload.matcher_hints["learned_tolerance_pct"],
               "a rent installment is not evidence rent varies"
  end

  test "confirming a suggestion settles the bill" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: -7)
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 85.50, date: Date.current, name: "CITY WATER")
    @matcher.run!

    RecurringTransaction::Allocator.new(occurrence).confirm_suggestion!(occurrence.allocations.sole)

    assert occurrence.reload.paid?
    assert occurrence.allocations.sole.from_user_confirmed?
  end

  # explain is what lets a surface show a person WHY something matched. The
  # payment picker used to rank by amount distance alone and never consult the
  # engine, which is how a Twitch charge could outrank the 7-Eleven charge for
  # a 7-Eleven bill.
  test "explain returns the signals behind a strong match" do
    series = create_series(name: nil, merchant: merchants(:netflix), amount: 15.99, day_offset: 0)
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 15.99, date: occurrence.due_on, merchant: merchants(:netflix))

    explanation = @matcher.explain(occurrence, entry)

    assert_not_nil explanation
    assert_equal 0.40, explanation.signals[:merchant]
    assert_equal 0.30, explanation.signals[:amount], "an exact amount scores the full 0.30"
    assert_equal 0.20, explanation.signals[:date], "landing on the due date scores the full 0.20"
    assert_operator explanation.confidence, :>=, Matcher::EXACT_TIER
  end

  test "explain refuses an entry from another merchant outright" do
    series = create_series(name: nil, merchant: merchants(:netflix), amount: 15.99, day_offset: 0)
    occurrence = series.recurring_occurrences.order(:due_on).first
    other = create_entry(amount: 15.99, date: occurrence.due_on, merchant: merchants(:amazon))

    assert_nil @matcher.explain(occurrence, other),
      "a same-amount same-day charge from a different merchant is not a weak match, it is not a match"
  end

  test "explain refuses an entry outside the date window" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0)
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 80, date: occurrence.due_on - 60, name: "CITY WATER")

    assert_nil @matcher.explain(occurrence, entry)
  end

  test "explain refuses an amount outside the tolerance band" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0)
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 400, date: occurrence.due_on, name: "CITY WATER")

    assert_nil @matcher.explain(occurrence, entry),
      "outside tolerance the score is a flat zero, and zero must not reach a picker"
  end


  # Allocations store magnitudes, entries store signs. A magnitude-only lookup
  # never matched a reposted paycheck, so orphaned income stayed orphaned.
  test "repair finds a reposted income entry by its signed amount" do
    series = create_series(name: "PAYCHECK CO", amount: -1840, day_offset: 0, bill_type: "income")
    occurrence = series.recurring_occurrences.order(:due_on).first
    original = create_entry(amount: -1840, date: Date.current, name: "PAYCHECK CO")
    @matcher.run!
    allocation = occurrence.allocations.sole

    original.destroy!
    assert_nil allocation.reload.entry_id

    replacement = create_entry(amount: -1840, date: allocation.paid_on, name: "PAYCHECK CO POSTED")
    @matcher.repair_orphans!

    assert_equal replacement.id, allocation.reload.entry_id
  end

  # Same day, same amount, different merchant is a coincidental twin, not the
  # bill's own repost, and attaching it reports the bill paid by a stranger.
  test "repair refuses a same-amount entry that is not the series' identity" do
    series = create_series(name: "POWER CO", amount: 60, day_offset: 0)
    occurrence = series.recurring_occurrences.order(:due_on).first
    original = create_entry(amount: 60, date: Date.current, name: "POWER CO")
    @matcher.run!
    allocation = occurrence.allocations.sole

    original.destroy!
    create_entry(amount: 60, date: allocation.paid_on, name: "SUSHI PALACE")

    @matcher.repair_orphans!

    assert_nil allocation.reload.entry_id, "a stranger with the same price is not the bill"
  end

  test "a recurring transfer is paid by the transfer into its destination account" do
    series = create_series(name: "Payment to Loan", amount: 500, day_offset: 0, destination: accounts(:loan))
    occurrence = series.recurring_occurrences.order(:due_on).first
    outflow = create_transfer(amount: 500, date: Date.current, to: accounts(:loan))

    assert_equal 1, @matcher.run!

    allocation = occurrence.allocations.sole
    assert allocation.allocation_confirmed?
    assert_equal outflow.id, allocation.entry_id
    assert allocation.match_signals.key?("transfer")
    assert occurrence.reload.paid?
  end

  test "a recurring transfer ignores transfers into another account and plain charges" do
    series = create_series(name: "Payment to Loan", amount: 500, day_offset: 0, destination: accounts(:loan))
    create_transfer(amount: 500, date: Date.current, to: accounts(:credit_card))
    create_entry(amount: 500, date: Date.current, name: "Payment to Loan")

    assert_equal 0, @matcher.run!
    assert_empty series.recurring_occurrences.flat_map(&:allocations)
  end

  test "an ordinary bill never matches a transfer leg, even with the same name" do
    series = create_series(name: "MORTGAGE DD", amount: 500, day_offset: 0)
    create_transfer(amount: 500, date: Date.current, to: accounts(:loan), name: "MORTGAGE DD")

    assert_equal 0, @matcher.run!
    assert_empty series.recurring_occurrences.flat_map(&:allocations)
  end

  test "backfill closes a recurring transfer's past occurrence from its transfer" do
    series = create_series(name: "Payment to Loan", amount: 500, day_offset: -30, destination: accounts(:loan))
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_transfer(amount: 500, date: occurrence.due_on, to: accounts(:loan))

    @matcher.run_backfill!

    assert occurrence.reload.paid?
  end

  test "explain scores a recurring transfer's own transfer and refuses others" do
    series = create_series(name: "Payment to Loan", amount: 500, day_offset: 0, destination: accounts(:loan))
    occurrence = series.recurring_occurrences.order(:due_on).first
    own = create_transfer(amount: 500, date: Date.current, to: accounts(:loan))
    other = create_transfer(amount: 500, date: Date.current, to: accounts(:credit_card))

    explanation = Matcher.new(@family).explain(occurrence, own)
    assert_operator explanation.confidence, :>=, Matcher::EXACT_TIER
    assert explanation.signals.key?(:transfer)
    assert_nil Matcher.new(@family).explain(occurrence, other)
  end

  # --- Bank reference (Verwendungszweck) -------------------------------------

  test "a bank reference lets a variable bill link although the amount is outside tolerance" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 130, date: Date.current, name: "CITY WATER", notes: "VN 4711 Abschlag Nov, IBAN DE02 1234")

    assert_equal 1, @matcher.run!

    allocation = occurrence.allocations.sole
    assert_equal entry.id, allocation.entry_id
    assert allocation.allocation_confirmed?
    assert_equal "VN 4711", allocation.match_signals["reference"],
      "only the matched reference is stored"
    assert_not_includes allocation.match_signals.to_json, "IBAN",
      "the third-party note itself is never persisted"
  end

  test "the same variable payment without a reference stays unmatched" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0)
    create_entry(amount: 130, date: Date.current, name: "CITY WATER", notes: "VN 4711 Abschlag")

    assert_equal 0, @matcher.run!
    assert_equal 0, series.recurring_occurrences.order(:due_on).first.allocations.count
  end

  test "a reference payment settles its cycle at half the expected figure, showing the real amount paid" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    half = create_entry(amount: 40, date: Date.current, name: "CITY WATER", notes: "VN 4711")

    assert_equal 1, @matcher.run!

    allocation = occurrence.allocations.sole
    assert_equal half.id, allocation.entry_id
    assert allocation.allocation_confirmed?
    assert_equal 40, allocation.allocated_amount.to_f
    assert occurrence.reload.paid?, "the reference says this is the cycle's payment, whatever it amounted to"
  end

  test "a reference payment of three times the expected figure is allocated whole and settles the cycle" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 240, date: Date.current, name: "CITY WATER", notes: "VN 4711")

    assert_equal 1, @matcher.run!

    allocation = occurrence.allocations.sole
    assert_equal 240, allocation.allocated_amount.to_f, "the real paid amount, not what the cycle still needed"
    assert occurrence.reload.paid?
    assert_equal 0, @matcher.run!, "a second run neither stacks nor raises on the used-up entry"
    assert_equal entry.id, occurrence.allocations.sole.entry_id
  end

  test "a series without a reference still needs a payment within tolerance to settle its cycle" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0)
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 81, date: Date.current, name: "CITY WATER")
    @matcher.run!
    assert occurrence.reload.paid?

    other = create_series(name: "POWER CO", amount: 100, day_offset: 0)
    other_occurrence = other.recurring_occurrences.order(:due_on).first
    create_entry(amount: 60, date: Date.current, name: "POWER CO")
    @matcher.run!
    assert_equal 0, other_occurrence.reload.allocations.count, "amount outside tolerance never matches without a reference"
  end

  test "a reference match with an off amount is only a suggestion for a pending charge" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: 130, date: Date.current, name: "CITY WATER", notes: "VN 4711",
                 extra: { "simplefin" => { "pending" => true } })

    @matcher.run!

    assert series.recurring_occurrences.order(:due_on).first.allocations.sole.allocation_suggested?
  end

  test "reference matching ignores case and runs of whitespace" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "vn   4711" })
    create_entry(amount: 130, date: Date.current, name: "CITY WATER", notes: "Abschlag VN\n4711 Nov")

    assert_equal 1, @matcher.run!
    assert series.recurring_occurrences.order(:due_on).first.allocations.sole.match_signals.key?("reference")
  end

  test "a note naming the reference on another account cannot pull in a foreign charge" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    accounts(:credit_card).entries.create!(
      date: Date.current, amount: 130, currency: "USD", name: "CITY WATER", notes: "VN 4711",
      entryable: Transaction.new
    )

    assert_equal 0, @matcher.run!
    assert_equal 0, series.recurring_occurrences.order(:due_on).first.allocations.count
  end

  test "an absent note or reference changes no score" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    plain = create_entry(amount: 80, date: Date.current, name: "CITY WATER")
    other_note = create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "something else")

    baseline = @matcher.explain(occurrence, plain)
    assert_equal baseline.confidence, @matcher.explain(occurrence, other_note).confidence
    assert_not baseline.signals.key?(:reference)
  end

  test "a reference match breaks a tie between two otherwise identical bills" do
    first = create_series(name: "GYM", amount: 40, day_offset: 0, dedup_scope: "a", hints: { "bank_reference" => "KV-111" })
    second = create_series(name: "GYM", amount: 40, day_offset: 0, dedup_scope: "b", hints: { "bank_reference" => "KV-222" })
    entry = create_entry(amount: 40, date: Date.current, name: "GYM", notes: "KV-222 membership")

    assert_equal 1, @matcher.run!

    assert_equal 0, first.recurring_occurrences.order(:due_on).first.allocations.count
    allocation = second.recurring_occurrences.order(:due_on).first.allocations.sole
    assert_equal entry.id, allocation.entry_id
    assert allocation.allocation_confirmed?
  end

  test "a note naming another series' reference on the same account excludes this series" do
    mine = create_series(name: "GYM", amount: 40, day_offset: 0, dedup_scope: "a", hints: { "bank_reference" => "KV-111" })
    create_series(name: "GYM", amount: 40, day_offset: 0, dedup_scope: "b", hints: { "bank_reference" => "KV-222" })
    entry = create_entry(amount: 40, date: Date.current, name: "GYM", notes: "KV-222")

    assert_nil @matcher.explain(mine.recurring_occurrences.order(:due_on).first, entry)
  end

  test "a reference match is exact tier even with a far-off amount and signals the deviation" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    entry = create_entry(amount: 400, date: Date.current - 1, name: "CITY WATER", notes: "VN 4711")

    explanation = @matcher.explain(series.recurring_occurrences.order(:due_on).first, entry)

    assert_operator explanation.confidence, :>=, Matcher::EXACT_TIER
    assert_equal "VN 4711", explanation.signals[:reference]
    assert_equal 0.0, explanation.signals[:amount]
  end

  test "a second reference payment in the same cycle is linked as an extra payment on that occurrence" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    first = create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "VN 4711")
    second = create_entry(amount: 95, date: Date.current - 1, name: "CITY WATER", notes: "VN 4711")

    assert_equal 2, @matcher.run!

    assert_equal [ first.id, second.id ].sort, occurrence.allocations.pluck(:entry_id).sort
    assert occurrence.reload.paid?
    assert_equal 0, Matcher.new(@family).run!, "no duplicate links on rerun"
    assert_equal 2, occurrence.allocations.count
  end

  test "a reference payment arriving after the cycle was paid is linked on a later run" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "VN 4711")
    @matcher.run!
    assert occurrence.reload.paid?

    later = create_entry(amount: 70, date: Date.current, name: "CITY WATER", notes: "VN 4711 Nachzahlung")
    assert_equal 1, Matcher.new(@family).run!

    assert_equal 2, occurrence.allocations.count
    assert_includes occurrence.allocations.pluck(:entry_id), later.id
    assert_equal 0, Matcher.new(@family).run!
  end

  test "a run closes an occurrence whose reference allocation was linked before the settle rule existed" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 60, date: Date.current, name: "CITY WATER", notes: "VN 4711")
    @matcher.run!
    occurrence.reload.reopen!
    assert occurrence.reload.scheduled?

    assert_equal 0, Matcher.new(@family).run_backfill!

    assert occurrence.reload.paid?, "the existing reference allocation settles the cycle on the next run"
    assert_equal 60, occurrence.allocations.sole.allocated_amount.to_f
  end

  test "a stale suggestion for a reference payment is confirmed instead of blocking the link" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 70, date: Date.current, name: "CITY WATER", notes: "VN 4711")
    occurrence.allocations.create!(entry: entry, allocated_amount: 70, currency: "USD", source_amount: 70, source_currency: "USD",
                                   state: "suggested", source: "auto_matched", match_confidence: 0.7, match_signals: {}, paid_on: entry.date)

    assert_equal 1, Matcher.new(@family).run_backfill!

    allocation = occurrence.allocations.sole
    assert allocation.allocation_confirmed?
    assert occurrence.reload.paid?
  end

  test "a stale suggestion on another occurrence does not use up the entry the reference now links" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    other = series.recurring_occurrences.order(:due_on).second
    assert other, "a later cycle exists"
    entry = create_entry(amount: 70, date: Date.current, name: "CITY WATER", notes: "VN 4711")
    other.allocations.create!(entry: entry, allocated_amount: 70, currency: "USD", source_amount: 70, source_currency: "USD",
                              state: "suggested", source: "auto_matched", match_confidence: 0.7, match_signals: {}, paid_on: entry.date)

    assert_equal 1, Matcher.new(@family).run_backfill!

    assert_equal [ occurrence.id ], RecurringAllocation.where(entry_id: entry.id).pluck(:recurring_occurrence_id)
    assert RecurringAllocation.find_by!(entry_id: entry.id).allocation_confirmed?
  end


  test "a paid occurrence takes no extra payment without the reference" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "VN 4711")
    @matcher.run!

    create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "no reference")

    assert_equal 0, Matcher.new(@family).run!
    assert_equal 1, occurrence.allocations.count
  end

  test "a reference payment links regardless of the date window: three days before the due date" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 3, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "VN 4711")

    assert_equal 1, @matcher.run!

    assert_equal entry.id, occurrence.allocations.sole.entry_id
    assert occurrence.reload.paid?
  end

  test "without the reference the same early payment stays outside the window" do
    create_series(name: "CITY WATER", amount: 80, day_offset: 3)
    create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "no reference")

    assert_equal 0, @matcher.run!
  end

  test "a reference payment goes to the nearest occurrence by due date, whatever the distance" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrences = series.recurring_occurrences.order(:due_on).to_a
    later = occurrences.second
    assert later, "a later cycle exists"
    entry = create_entry(amount: 80, date: later.due_on - 11, name: "CITY WATER", notes: "VN 4711")

    Matcher.new(@family).run_backfill!

    assert_equal later.id, RecurringAllocation.find_by!(entry_id: entry.id).recurring_occurrence_id
  end

  test "a tie between a paid and an open occurrence goes to the open one" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: -10, hints: { "bank_reference" => "VN 4711" })
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 100)
    first, second = series.recurring_occurrences.order(:due_on).first(2)
    create_entry(amount: 80, date: first.due_on, name: "CITY WATER", notes: "VN 4711")
    @matcher.run!
    assert first.reload.paid?
    midpoint = first.due_on + ((second.due_on - first.due_on).to_i / 2)
    entry = create_entry(amount: 80, date: midpoint, name: "CITY WATER", notes: "VN 4711")
    tie = (entry.date - first.due_on).to_i == (second.due_on - entry.date).to_i

    Matcher.new(@family).run!

    expected = tie ? second : (entry.date - first.due_on).to_i < (second.due_on - entry.date).to_i ? first : second
    assert_equal expected.id, RecurringAllocation.find_by!(entry_id: entry.id).recurring_occurrence_id
  end

  test "a reference payment long before the series' first cycle is left alone without error" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    old = create_entry(amount: 80, date: Date.current - 400, name: "CITY WATER", notes: "VN 4711")

    assert_equal 0, Matcher.new(@family).run_backfill!
    assert_equal 0, RecurringAllocation.where(entry_id: old.id).count
    assert_operator series.recurring_occurrences.count, :>, 0
  end

  test "a reference payment within a cycle before the series' first cycle attaches to that first cycle" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    first = series.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 80, date: first.due_on - 20, name: "CITY WATER", notes: "VN 4711")

    assert_equal 1, Matcher.new(@family).run_backfill!
    assert_equal first.id, RecurringAllocation.find_by!(entry_id: entry.id).recurring_occurrence_id
  end

  # Earlier builds paired a payment with a farther cycle when the nearest one
  # was taken; those confirmed allocations are re-homed to the nearest cycle.
  test "a run re-homes an auto-created reference allocation to the nearest cycle and swaps the cycles' states" do
    series = create_series(name: "Home Loan", amount: 1200.00, day_offset: -40, hints: { "bank_reference" => "REF 123 456" })
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 140)
    cycles = series.recurring_occurrences.order(:due_on).to_a
    old_cycle = cycles.first
    near = cycles.find { |cycle| cycle.due_on >= Date.current - 40 } || cycles.last
    entry = create_entry(amount: 1200.00, date: near.due_on - 3, name: "Example Bank", notes: "REF 123 456 Rate")
    stale = RecurringTransaction::Allocator.new(old_cycle).allocate_matched!(entry: entry, state: "confirmed", confidence: 1, signals: { reference: "REF 123 456" })
    assert old_cycle.reload.paid?

    @matcher.run_backfill!

    assert_equal near.id, stale.reload.recurring_occurrence_id, "moved to the nearest cycle"
    assert_equal 1, RecurringAllocation.where(entry_id: entry.id).count
    assert near.reload.paid?
    assert old_cycle.reload.scheduled?, "the cycle it was wrongly settling is open again"
  end

  # Two bills for the same payee and amount told apart only by their references:
  # a confirmed name-identity allocation of one bill sitting on a payment that
  # carries the other bill's reference is released so the right bill can link it.
  test "a run releases a confirmed auto allocation whose note names another bill's reference and the other bill links it" do
    alex = create_series(name: "Lens Plan", amount: 20.90, day_offset: -10, hints: { "bank_reference" => "Lens Plan Alex" })
    sam = create_series(name: "Lens Plan", amount: 20.90, day_offset: -10, dedup_scope: "sam", hints: { "bank_reference" => "Lens Plan Sam" })
    [ alex, sam ].each { |series| RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 100) }
    month = alex.recurring_occurrences.order(:due_on).first
    own = create_entry(amount: 20.90, date: month.due_on, name: "Lens Shop", notes: "Lens Plan Alex")
    foreign = create_entry(amount: 20.90, date: month.due_on, name: "Lens Shop", notes: "Lens Plan Sam")
    allocator = RecurringTransaction::Allocator.new(month)
    allocator.allocate_matched!(entry: own, state: "confirmed", confidence: 1, signals: { reference: "Lens Plan Alex" })
    allocator.allocate_matched!(entry: foreign, state: "confirmed", confidence: 1, signals: { name: true })

    @matcher.run_backfill!

    assert_equal [ own.id ], alex.recurring_occurrences.flat_map { |cycle| cycle.allocations.pluck(:entry_id) }
    assert_equal [ foreign.id ], sam.recurring_occurrences.flat_map { |cycle| cycle.allocations.pluck(:entry_id) }
    assert sam.recurring_occurrences.order(:due_on).first.reload.paid?
  end

  test "releasing foreign-reference allocations is idempotent" do
    alex = create_series(name: "Lens Plan", amount: 20.90, day_offset: -10, hints: { "bank_reference" => "Lens Plan Alex" })
    sam = create_series(name: "Lens Plan", amount: 20.90, day_offset: -10, dedup_scope: "sam", hints: { "bank_reference" => "Lens Plan Sam" })
    [ alex, sam ].each { |series| RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 100) }
    month = alex.recurring_occurrences.order(:due_on).first
    foreign = create_entry(amount: 20.90, date: month.due_on, name: "Lens Shop", notes: "Lens Plan Sam")
    RecurringTransaction::Allocator.new(month).allocate_matched!(entry: foreign, state: "confirmed", confidence: 1, signals: { name: true })

    @matcher.run_backfill!
    state = RecurringAllocation.order(:id).pluck(:entry_id, :recurring_occurrence_id, :state)
    Matcher.new(@family).run_backfill!

    assert_equal state, RecurringAllocation.order(:id).pluck(:entry_id, :recurring_occurrence_id, :state)
  end

  test "a person's own choice is never released for naming another bill's reference" do
    alex = create_series(name: "Lens Plan", amount: 20.90, day_offset: -10, hints: { "bank_reference" => "Lens Plan Alex" })
    create_series(name: "Lens Plan", amount: 20.90, day_offset: -10, dedup_scope: "sam", hints: { "bank_reference" => "Lens Plan Sam" })
    month = RecurringTransaction::OccurrenceGenerator.new(alex).backfill!(from: Date.current - 100) && alex.recurring_occurrences.order(:due_on).first
    entry = create_entry(amount: 20.90, date: month.due_on, name: "Lens Shop", notes: "Lens Plan Sam")
    chosen = month.allocations.create!(entry: entry, allocated_amount: 20.90, currency: "USD", state: "confirmed", source: "user_confirmed", paid_on: entry.date)

    @matcher.run_backfill!

    assert RecurringAllocation.exists?(chosen.id)
  end

  test "a reference-only bill releases an auto allocation whose note lacks its reference" do
    series = create_series(name: "Lens Plan", amount: 20.90, day_offset: -10, hints: { "bank_reference" => "Lens Plan Alex", "reference_only" => true })
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 100)
    month = series.recurring_occurrences.order(:due_on).first
    bare = create_entry(amount: 20.90, date: month.due_on, name: "Lens Plan", notes: "monthly fee")
    kept = create_entry(amount: 20.90, date: month.due_on, name: "Lens Shop", notes: "Lens Plan Alex")
    allocator = RecurringTransaction::Allocator.new(month)
    allocator.allocate_matched!(entry: bare, state: "confirmed", confidence: 1, signals: { name: true })
    allocator.allocate_matched!(entry: kept, state: "confirmed", confidence: 1, signals: { reference: "Lens Plan Alex" })

    @matcher.run_backfill!

    assert_nil RecurringAllocation.find_by(entry_id: bare.id)
    assert RecurringAllocation.exists?(entry_id: kept.id)
  end

  test "re-homing is idempotent" do
    series = create_series(name: "Home Loan", amount: 100, day_offset: -40, hints: { "bank_reference" => "REF 123 456" })
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 140)
    cycles = series.recurring_occurrences.order(:due_on).to_a
    near = cycles.find { |cycle| cycle.due_on >= Date.current - 40 } || cycles.last
    entry = create_entry(amount: 100, date: near.due_on, name: "Example Bank", notes: "REF 123 456")
    RecurringTransaction::Allocator.new(cycles.first).allocate_matched!(entry: entry, state: "confirmed", confidence: 1, signals: { reference: "REF 123 456" })

    @matcher.run_backfill!
    snapshot = RecurringAllocation.pluck(:id, :recurring_occurrence_id, :updated_at)
    Matcher.new(@family).run_backfill!
    Matcher.new(@family).run!

    assert_equal snapshot, RecurringAllocation.pluck(:id, :recurring_occurrence_id, :updated_at)
  end

  test "re-homing never touches hand-made or non-reference allocations" do
    series = create_series(name: "Home Loan", amount: 100, day_offset: -40, hints: { "bank_reference" => "REF 123 456" })
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 140)
    cycles = series.recurring_occurrences.order(:due_on).to_a
    far = cycles.first
    near = cycles.find { |cycle| cycle.due_on >= Date.current - 40 } || cycles.last
    by_hand = create_entry(amount: 100, date: near.due_on, name: "Example Bank", notes: "REF 123 456")
    no_signal = create_entry(amount: 100, date: near.due_on - 1, name: "Example Bank", notes: "REF 123 456")
    kept = RecurringTransaction::Allocator.new(far).allocate_matched!(entry: no_signal, state: "confirmed", confidence: 1, signals: { name: 0.35 })
    hand = far.allocations.create!(entry: by_hand, allocated_amount: 100, currency: "USD", source_amount: 100, source_currency: "USD",
                                   state: "confirmed", source: "user_confirmed", match_signals: { "reference" => "REF 123 456" }, paid_on: by_hand.date)

    @matcher.run_backfill!

    assert_equal far.id, hand.reload.recurring_occurrence_id, "a user's own choice stays"
    assert_equal far.id, kept.reload.recurring_occurrence_id, "an allocation without the reference signal stays"
  end


  test "a rejected reference payment is never linked, however near" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 3, hints: { "bank_reference" => "VN 4711" })
    entry = create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "VN 4711")
    RecurringMatchRejection.create!(recurring_transaction: series, entry: entry)

    assert_equal 0, @matcher.run!
  end

  test "reference identity matches whatever the amount" do
    create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: 400, date: Date.current, name: "Example Energy GmbH", notes: "VN 4711")

    assert_equal 1, @matcher.run!
  end

  test "reference identity still needs the right sign and account" do
    create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: -80, date: Date.current, name: "Example Energy GmbH", notes: "VN 4711")
    accounts(:credit_card).entries.create!(
      date: Date.current, amount: 80, currency: "USD", name: "Example", notes: "VN 4711", entryable: Transaction.new
    )

    assert_equal 0, @matcher.run!
  end

  test "a differently named payee without the reference still does not match" do
    create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: 80, date: Date.current, name: "Example Energy GmbH", notes: "other contract")

    assert_equal 0, @matcher.run!
  end

  test "a reference never makes an ordinary bill claim a transfer leg" do
    create_series(name: "Strom", amount: 500, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    create_transfer(amount: 500, date: Date.current, to: accounts(:loan), notes: "VN 4711")

    assert_equal 0, @matcher.run!
  end

  test "explain accepts a reference-identified payee" do
    series = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    entry = create_entry(amount: 80, date: Date.current, name: "Example Energy GmbH", notes: "VN 4711")

    assert_not_nil @matcher.explain(series.recurring_occurrences.order(:due_on).first, entry)
  end

  test "repair re-attaches a reposted payment by reference although its name changed" do
    series = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    original = create_entry(amount: 80, date: Date.current, name: "Example Energy GmbH", notes: "VN 4711")
    @matcher.run!
    allocation = occurrence.allocations.sole
    original.destroy!
    replacement = create_entry(amount: 80, date: allocation.paid_on, name: "PENDING EXAMPLE", notes: "VN 4711")

    Matcher.new(@family).repair_orphans!

    assert_equal replacement.id, allocation.reload.entry_id
  end

  test "reference-only: the reference is the only identity, a matching name without it never links" do
    series = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711", "reference_only" => true })
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 80, date: Date.current, name: "Strom", notes: "other contract")
    assert_equal 0, @matcher.run!

    entry = create_entry(amount: 80, date: Date.current, name: "Example Energy GmbH", notes: "VN 4711")
    assert_equal 1, @matcher.run!
    assert_equal entry.id, occurrence.allocations.sole.entry_id
  end

  test "reference-only does not compare the merchant" do
    series = create_series(name: nil, merchant: merchants(:netflix), amount: 80, day_offset: 0,
                           hints: { "bank_reference" => "VN 4711", "reference_only" => true })
    create_entry(amount: 80, date: Date.current, name: "Other", merchant: merchants(:amazon), notes: "VN 4711")

    assert_equal 1, @matcher.run!
    assert_equal 1, series.recurring_occurrences.order(:due_on).first.allocations.count
  end

  test "reference-only scores the reference in place of the name, so scores are not inflated" do
    series = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711", "reference_only" => true })
    entry = create_entry(amount: 80, date: Date.current, name: "Example", notes: "VN 4711")

    explanation = @matcher.explain(series.recurring_occurrences.order(:due_on).first, entry)

    assert_equal "VN 4711", explanation.signals[:reference]
    assert_not explanation.signals.key?(:name)
    assert_not explanation.signals.key?(:merchant)
    assert_in_delta 0.95, explanation.confidence, 0.001
  end

  test "reference-only is ignored without a reference" do
    create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "reference_only" => true })
    create_entry(amount: 80, date: Date.current, name: "Strom")

    assert_equal 1, @matcher.run!
  end

  test "reference-only keeps account and sign" do
    create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711", "reference_only" => true })
    create_entry(amount: -80, date: Date.current, name: "Example", notes: "VN 4711")
    accounts(:credit_card).entries.create!(
      date: Date.current, amount: 80, currency: "USD", name: "Example", notes: "VN 4711", entryable: Transaction.new
    )

    assert_equal 0, @matcher.run!
  end

  test "reference-only on a recurring transfer needs the account pair and the reference" do
    series = create_series(name: "Transfer one", amount: 2000, day_offset: 0, destination: accounts(:loan), bill_type: "transfer",
                           hints: { "bank_reference" => "Contract_1", "reference_only" => true })
    create_transfer(amount: 2000, date: Date.current, to: accounts(:loan), notes: "no reference")
    create_transfer(amount: 2000, date: Date.current, to: accounts(:credit_card), notes: "Contract_1")
    assert_equal 0, @matcher.run!

    entry = create_transfer(amount: 2000, date: Date.current, to: accounts(:loan), notes: "Contract_1")
    assert_equal 1, @matcher.run!
    assert_equal entry.id, series.recurring_occurrences.order(:due_on).first.allocations.sole.entry_id
  end

  test "reference-only repair re-attaches only an entry carrying the reference" do
    series = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711", "reference_only" => true })
    occurrence = series.recurring_occurrences.order(:due_on).first
    original = create_entry(amount: 80, date: Date.current, name: "Example", notes: "VN 4711")
    @matcher.run!
    allocation = occurrence.allocations.sole
    original.destroy!
    create_entry(amount: 80, date: allocation.paid_on, name: "Strom", notes: "other")
    replacement = create_entry(amount: 80, date: allocation.paid_on, name: "Whatever", notes: "VN 4711")

    Matcher.new(@family).repair_orphans!

    assert_equal replacement.id, allocation.reload.entry_id
  end

  test "backfill closes a variable bill's past occurrence by reference" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: -40, hints: { "bank_reference" => "VN 4711" })
    occurrence = series.recurring_occurrences.order(:due_on).first
    create_entry(amount: 130, date: occurrence.due_on, name: "CITY WATER", notes: "VN 4711")

    @matcher.run_backfill!

    assert occurrence.reload.paid?
  end

  # --- review follow-ups -----------------------------------------------------

  test "a future-dated entry carrying the reference settles nothing in a live run" do
    series = create_series(name: "Strom", amount: 80, day_offset: 2, hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: 80, date: Date.current + 5, name: "Example Energy", notes: "VN 4711")

    assert_equal 0, @matcher.run!
    assert_empty series.recurring_occurrences.flat_map(&:allocations)
  end

  test "a recurring transfer whose reference is only on the receiving leg links outside the date window" do
    series = create_series(name: "Allowance", amount: 250, day_offset: -3, destination: accounts(:loan), bill_type: "transfer",
                           hints: { "bank_reference" => "ALLOW 77" })
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 100)
    entry = create_transfer(amount: 250, date: Date.current - 118, to: accounts(:loan), notes: "plain", inflow_notes: "ALLOW 77 monthly")

    assert_operator @matcher.run_backfill!, :>=, 1
    assert RecurringAllocation.exists?(entry_id: entry.id)
  end

  test "a reference payment nearer an old settled annual cycle than the next one lands on the old cycle" do
    due = Date.current - 250
    series = create_series(name: "Insurance", amount: 400, day_offset: -250, hints: { "bank_reference" => "POL 55" })
    RecurringTransaction::FrequencyPreset.apply(series, preset: "annual", day_of_month: due.day, month_of_year: due.month)
    series.save!
    series.recurring_occurrences.destroy_all
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: due - 1)
    RecurringTransaction::OccurrenceGenerator.new(series).generate!
    old_cycle = series.recurring_occurrences.order(:due_on).first
    assert_equal due, old_cycle.due_on
    first = create_entry(amount: 400, date: due, name: "Example Insurer", notes: "POL 55")
    RecurringTransaction::Allocator.new(old_cycle).allocate_matched!(entry: first, state: "confirmed", confidence: 1, signals: { reference: "POL 55" })
    assert old_cycle.reload.paid?
    extra = create_entry(amount: 120, date: due + 170, name: "Example Insurer", notes: "POL 55 extra")

    @matcher.run!

    assert_equal old_cycle.id, RecurringAllocation.find_by!(entry_id: extra.id).recurring_occurrence_id
  end

  test "orphan repair never re-attaches an opposite-sign entry or a transfer leg to an ordinary bill by reference" do
    series = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    original = create_entry(amount: 80, date: Date.current, name: "Example Energy", notes: "VN 4711")
    @matcher.run!
    allocation = series.recurring_occurrences.order(:due_on).first.allocations.sole
    original.destroy!
    create_entry(amount: -80, date: allocation.paid_on, name: "Example Energy", notes: "VN 4711")
    create_transfer(amount: 80, date: allocation.paid_on, to: accounts(:loan), notes: "VN 4711")

    Matcher.new(@family).repair_orphans!

    assert_nil allocation.reload.entry_id
  end

  test "a payment moved to its nearest cycle replaces a suggestion the entry holds there and keeps both cycles consistent" do
    series = create_series(name: "Home Loan", amount: 1200.00, day_offset: -40, hints: { "bank_reference" => "REF 123 456" })
    RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: Date.current - 140)
    cycles = series.recurring_occurrences.order(:due_on).to_a
    old_cycle = cycles.first
    near = cycles.find { |cycle| cycle.due_on >= Date.current - 40 } || cycles.last
    entry = create_entry(amount: 1200.00, date: near.due_on - 3, name: "Example Bank", notes: "REF 123 456 Rate")
    confirmed = RecurringTransaction::Allocator.new(old_cycle).allocate_matched!(entry: entry, state: "confirmed", confidence: 1, signals: { reference: "REF 123 456" })
    near.allocations.create!(entry: entry, allocated_amount: 10, currency: "USD", state: "suggested", source: "auto_matched", match_confidence: 0.7, match_signals: {}, paid_on: entry.date)

    @matcher.run_backfill!

    assert_equal near.id, confirmed.reload.recurring_occurrence_id
    assert_equal [ "confirmed" ], RecurringAllocation.where(entry_id: entry.id).pluck(:state)
    assert near.reload.paid?
    assert old_cycle.reload.scheduled?
  end

  test "diagnose only pairs a bill without a reference with its open cycles" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0)
    paid = series.recurring_occurrences.order(:due_on).first
    first = create_entry(amount: 80, date: paid.due_on, name: "CITY WATER")
    @matcher.run!
    assert paid.reload.paid?
    second = create_entry(amount: 80, date: paid.due_on, name: "CITY WATER")

    facts = @matcher.diagnose(series, second)

    assert_not_equal paid.id, facts.nearest&.id
    assert first.present?
  end

  test "diagnose copes with a reference bill that has no cycles" do
    series = create_series(name: "CITY WATER", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    series.recurring_occurrences.destroy_all
    entry = create_entry(amount: 80, date: Date.current, name: "CITY WATER", notes: "VN 4711")

    facts = @matcher.diagnose(series, entry)

    assert_nil facts.nearest
    assert_nil facts.confidence
  end

  test "two bills matching the same reference through different paths stay ambiguous" do
    ordinary = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    only = create_series(name: "Other name", amount: 80, day_offset: 0, dedup_scope: "only", hints: { "bank_reference" => "VN 4711", "reference_only" => true })
    entry = create_entry(amount: 80, date: Date.current, name: "Strom", notes: "VN 4711")

    @matcher.run!

    assert_empty RecurringAllocation.confirmed.where(entry_id: entry.id), "a tie is never auto-confirmed"
    assert ordinary.present? && only.present?
  end

  test "two bills matching the same reference are resolved by how well the payment fits" do
    close = create_series(name: "Strom", amount: 80, day_offset: 0, hints: { "bank_reference" => "VN 4711" })
    create_series(name: "Strom", amount: 80, day_offset: 20, dedup_scope: "far", hints: { "bank_reference" => "VN 4711" })
    entry = create_entry(amount: 80, date: Date.current, name: "Strom", notes: "VN 4711")

    @matcher.run!

    assert_equal close.id, RecurringAllocation.find_by!(entry_id: entry.id).recurring_occurrence.recurring_transaction_id
  end

  private
    def create_series(amount:, day_offset:, name: nil, merchant: nil, dedup_scope: "", preset: "monthly", bill_type: "bill", destination: nil, hints: {})
      due = Date.current + day_offset

      series = @family.recurring_transactions.create!(
        name: name,
        merchant: merchant,
        account: @account,
        destination_account: destination,
        amount: amount,
        currency: "USD",
        bill_type: bill_type,
        dedup_scope: dedup_scope,
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: true,
        matcher_hints: hints
      )

      if preset != "monthly"
        RecurringTransaction::FrequencyPreset.apply(series, preset: preset, weekday: due.wday)
        series.save!
      end

      series
    end

    # The outflow leg of a confirmed transfer from @account into `to`.
    def create_transfer(amount:, date:, to:, name: "Transfer", notes: nil, inflow_notes: nil)
      outflow = create_entry(amount: amount, date: date, name: name, notes: notes)
      outflow.entryable.update!(kind: "loan_payment")
      inflow = to.entries.create!(
        date: date, amount: -amount, currency: "USD", name: name, notes: inflow_notes,
        entryable: Transaction.new(kind: "funds_movement")
      )
      Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")
      outflow
    end

    def create_entry(amount:, date:, name: "charge", merchant: nil, extra: {}, notes: nil)
      @account.entries.create!(
        date: date,
        notes: notes,
        amount: amount,
        currency: "USD",
        name: name,
        entryable: Transaction.new(merchant: merchant, extra: extra)
      )
    end
end
