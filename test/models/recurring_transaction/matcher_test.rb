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

  private
    def create_series(amount:, day_offset:, name: nil, merchant: nil, dedup_scope: "", preset: "monthly", bill_type: "bill")
      due = Date.current + day_offset

      series = @family.recurring_transactions.create!(
        name: name,
        merchant: merchant,
        account: @account,
        amount: amount,
        currency: "USD",
        bill_type: bill_type,
        dedup_scope: dedup_scope,
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: true
      )

      if preset != "monthly"
        RecurringTransaction::FrequencyPreset.apply(series, preset: preset, weekday: due.wday)
        series.save!
      end

      series
    end

    def create_entry(amount:, date:, name: "charge", merchant: nil, extra: {})
      @account.entries.create!(
        date: date,
        amount: amount,
        currency: "USD",
        name: name,
        entryable: Transaction.new(merchant: merchant, extra: extra)
      )
    end
end
