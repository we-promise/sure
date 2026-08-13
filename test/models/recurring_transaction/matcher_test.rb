require "test_helper"

class RecurringTransaction::MatcherTest < ActiveSupport::TestCase
  Matcher = RecurringTransaction::Matcher

  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
    @matcher = Matcher.new(@family)
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

  private
    def create_series(amount:, day_offset:, name: nil, merchant: nil, dedup_scope: "", preset: "monthly")
      due = Date.current + day_offset

      series = @family.recurring_transactions.create!(
        name: name,
        merchant: merchant,
        account: @account,
        amount: amount,
        currency: "USD",
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
