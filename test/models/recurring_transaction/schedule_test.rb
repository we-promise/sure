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

  test "matching window is circular: a month-end entry matches a day-1 bill" do
    # A bill on the 1st paid a day or two early posts at the END of the prior
    # month. The window wraps the calendar circle, matching the Identifier's
    # matcher; the pre-unification SQL window [1, 3] silently missed these.
    recurring = create_recurring(expected_day_of_month: 1)
    in_window = create_matching_entry(recurring, date: Date.new(2026, 7, 2))
    wrapped = create_matching_entry(recurring, date: Date.new(2026, 7, 30))
    outside = create_matching_entry(recurring, date: Date.new(2026, 7, 27))

    matches = recurring.matching_transactions
    assert_includes matches, in_window
    assert_includes matches, wrapped
    assert_not_includes matches, outside
  end

  test "matching window for day 31 keeps its two-day reach" do
    recurring = create_recurring(expected_day_of_month: 31)
    in_window = create_matching_entry(recurring, date: Date.new(2026, 7, 29))
    outside = create_matching_entry(recurring, date: Date.new(2026, 7, 28))

    matches = recurring.matching_transactions
    assert_includes matches, in_window
    assert_not_includes matches, outside
  end

  test "matching window clamps the expected day into short months" do
    # A day-31 bill in February is due on the 28th; an entry on the 27th is one
    # day off the clamped day and must match. Unclamped, it read as four days
    # from the 31st and was dropped.
    recurring = create_recurring(expected_day_of_month: 31)
    clamped = create_matching_entry(recurring, date: Date.new(2026, 2, 27))

    assert_includes recurring.matching_transactions, clamped
  end

  # --- Schedule's own surface (new in the extraction) ---

  test "occurrences_between returns each monthly occurrence in the range inclusively" do
    schedule = RecurringTransaction::Schedule.new(expected_day_of_month: 15)
    assert_equal [ Date.new(2026, 8, 15), Date.new(2026, 9, 15), Date.new(2026, 10, 15) ],
                 schedule.occurrences_between(Date.new(2026, 8, 15), Date.new(2026, 10, 20))
  end

  test "occurrences_between skips a first occurrence before the range start" do
    schedule = RecurringTransaction::Schedule.new(expected_day_of_month: 5)
    assert_equal [ Date.new(2026, 9, 5) ],
                 schedule.occurrences_between(Date.new(2026, 8, 20), Date.new(2026, 9, 30))
  end

  test "occurrences_between clamps through short months without losing the day" do
    schedule = RecurringTransaction::Schedule.new(expected_day_of_month: 31)
    assert_equal [ Date.new(2026, 1, 31), Date.new(2026, 2, 28), Date.new(2026, 3, 31) ],
                 schedule.occurrences_between(Date.new(2026, 1, 1), Date.new(2026, 4, 15))
  end

  test "occurrences_between is empty for an inverted range" do
    schedule = RecurringTransaction::Schedule.new(expected_day_of_month: 15)
    assert_empty schedule.occurrences_between(Date.new(2026, 9, 1), Date.new(2026, 8, 1))
  end

  test "cycle_for brackets a date between its surrounding occurrences" do
    schedule = RecurringTransaction::Schedule.new(expected_day_of_month: 29)
    cycle = schedule.cycle_for(Date.new(2026, 8, 10))
    assert_equal Date.new(2026, 7, 29), cycle.begin
    assert_equal Date.new(2026, 8, 29), cycle.end
    assert cycle.exclude_end?

    on_day = schedule.cycle_for(Date.new(2026, 8, 29))
    assert_equal Date.new(2026, 8, 29), on_day.begin
    assert_equal Date.new(2026, 9, 29), on_day.end
  end

  test "matches_day on a weekly cadence follows the weekday, not the day of month" do
    schedule = build_schedule(rules: [ rule(frequency: "weekly", weekday: 5) ])

    # Fridays across a month boundary sit on wildly different days of month.
    assert schedule.matches_day?(Date.new(2026, 5, 29))
    assert schedule.matches_day?(Date.new(2026, 6, 5))
    assert schedule.matches_day?(Date.new(2026, 6, 19))
    assert_not schedule.matches_day?(Date.new(2026, 6, 18)), "a Thursday is not this bill's day"
  end

  test "matches_day on a weekly rule without a weekday falls back to the anchor's weekday" do
    schedule = build_schedule(
      rules: [ rule(frequency: "weekly", weekday: nil, interval: 2) ],
      anchor_date: Date.new(2026, 8, 7)
    )

    assert schedule.matches_day?(Date.new(2026, 8, 21)), "a Friday two weeks after the anchor"
    assert_not schedule.matches_day?(Date.new(2026, 8, 13))
  end

  test "matches_day on a biweekly cadence rejects the off week's weekday" do
    schedule = build_schedule(
      rules: [ rule(frequency: "weekly", weekday: 5, interval: 2) ],
      anchor_date: Date.new(2026, 8, 7)
    )

    assert schedule.matches_day?(Date.new(2026, 8, 7))
    assert schedule.matches_day?(Date.new(2026, 8, 21))
    assert_not schedule.matches_day?(Date.new(2026, 8, 14)),
      "the right weekday in the wrong week is not this bill's day"
  end

  test "matches_day on an every-N-months cadence rejects the off months" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15, interval: 3) ],
      anchor_date: Date.new(2026, 2, 15)
    )

    assert schedule.matches_day?(Date.new(2026, 5, 15))
    assert schedule.matches_day?(Date.new(2026, 5, 17)), "day drift inside the tolerance still matches"
    assert_not schedule.matches_day?(Date.new(2026, 4, 15)),
      "the right day of month in an off-cycle month is not this bill's day"
  end

  test "matches_day stops matching once the series has ended on a date" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15) ],
      end_mode: "on_date", end_on: Date.new(2026, 8, 15)
    )

    assert schedule.matches_day?(Date.new(2026, 7, 15)), "history inside the window still matches"
    assert schedule.matches_day?(Date.new(2026, 8, 15)), "the final occurrence still matches"
    assert_not schedule.matches_day?(Date.new(2026, 9, 15)),
      "a date after the series ended is not this bill's day"
  end

  test "matches_day stops matching after the occurrence count is exhausted" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15) ],
      anchor_date: Date.new(2026, 5, 15),
      end_mode: "after_count", end_after_count: 3
    )

    assert schedule.matches_day?(Date.new(2026, 5, 15)), "the first occurrence of the plan matches"
    assert schedule.matches_day?(Date.new(2026, 7, 15)), "the third and final occurrence matches"
    assert_not schedule.matches_day?(Date.new(2026, 8, 15)),
      "a fourth occurrence never exists under a three-payment plan"
  end

  test "matches_day follows a weekend-adjusted occurrence to the day it is due" do
    # Saturdays adjusted forward land on Monday, two days off the raw weekday,
    # which the exact weekly match would otherwise reject.
    schedule = build_schedule(
      rules: [ rule(frequency: "weekly", weekday: 6) ],
      weekend_adjust: "after"
    )

    # Aug 15 2026 is a Saturday, so the payment is due Monday Aug 17.
    assert schedule.matches_day?(Date.new(2026, 8, 17)), "the Monday the bill is actually due"
    assert schedule.matches_day?(Date.new(2026, 8, 15)), "the raw scheduled Saturday still matches"
    assert_not schedule.matches_day?(Date.new(2026, 8, 18)), "a Tuesday is neither scheduled nor due"
  end

  test "matches_day does not match an occurrence the weekend skip removed" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15) ],
      weekend_adjust: "skip"
    )

    # Aug 15 2026 is a Saturday, so skip drops that month's occurrence entirely.
    assert_not schedule.matches_day?(Date.new(2026, 8, 15)),
      "a skipped occurrence does not exist, so its day matches nothing"
    assert schedule.matches_day?(Date.new(2026, 9, 15)), "a weekday occurrence is unaffected by skip"
  end

  # --- Rules-based engine ---

  test "weekly rule fires every week on its weekday" do
    schedule = build_schedule(rules: [ rule(frequency: "weekly", weekday: 5) ])
    # Fridays in August 2026: 7, 14, 21, 28
    assert_equal [ 7, 14, 21, 28 ].map { |d| Date.new(2026, 8, d) },
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 8, 31))
  end

  test "weekly rule without a weekday generates on the anchor's weekday" do
    schedule = build_schedule(
      rules: [ rule(frequency: "weekly", weekday: nil) ],
      anchor_date: Date.new(2026, 8, 7)
    )
    # Fridays, inherited from the Friday anchor — same fallback matches_day? uses.
    assert_equal [ 7, 14, 21, 28 ].map { |d| Date.new(2026, 8, d) },
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 8, 31))
  end

  test "weekly rule with neither weekday nor anchor cannot generate occurrences" do
    schedule = build_schedule(rules: [ rule(frequency: "weekly", weekday: nil) ])
    assert_raises(ArgumentError) do
      schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 8, 31))
    end
  end

  test "biweekly rule keeps the anchor's phase, backward and forward" do
    schedule = build_schedule(
      rules: [ rule(frequency: "weekly", weekday: 5, interval: 2) ],
      anchor_date: Date.new(2026, 8, 7)
    )
    assert_equal [ Date.new(2026, 7, 24), Date.new(2026, 8, 7), Date.new(2026, 8, 21), Date.new(2026, 9, 4) ],
                 schedule.occurrences_between(Date.new(2026, 7, 20), Date.new(2026, 9, 10))
  end

  test "semimonthly is two monthly rules" do
    schedule = build_schedule(rules: [
      rule(frequency: "monthly", day_of_month: 1),
      rule(frequency: "monthly", day_of_month: 15)
    ])
    assert_equal [ Date.new(2026, 8, 1), Date.new(2026, 8, 15), Date.new(2026, 9, 1), Date.new(2026, 9, 15) ],
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 20))
  end

  test "day_of_month -1 means the last day of every month" do
    schedule = build_schedule(rules: [ rule(frequency: "monthly", day_of_month: -1) ])
    assert_equal [ Date.new(2026, 1, 31), Date.new(2026, 2, 28), Date.new(2026, 3, 31) ],
                 schedule.occurrences_between(Date.new(2026, 1, 1), Date.new(2026, 4, 1))
  end

  test "nth weekday rule finds the third friday" do
    schedule = build_schedule(rules: [ rule(frequency: "monthly", weekday: 5, weekday_ordinal: 3) ])
    assert_equal [ Date.new(2026, 8, 21), Date.new(2026, 9, 18) ],
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 30))
  end

  test "fifth weekday months are skipped when the month has no fifth" do
    schedule = build_schedule(rules: [ rule(frequency: "monthly", weekday: 1, weekday_ordinal: 5) ])
    # August 2026 has five Mondays (31st); September has only four.
    assert_equal [ Date.new(2026, 8, 31) ],
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 30))
  end

  test "ordinal -1 is the last weekday of the month" do
    schedule = build_schedule(rules: [ rule(frequency: "monthly", weekday: 5, weekday_ordinal: -1) ])
    assert_equal [ Date.new(2026, 8, 28), Date.new(2026, 9, 25) ],
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 30))
  end

  test "quarterly keeps the anchor's month phase" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15, interval: 3) ],
      anchor_date: Date.new(2026, 2, 15)
    )
    assert_equal [ Date.new(2026, 2, 15), Date.new(2026, 5, 15), Date.new(2026, 8, 15) ],
                 schedule.occurrences_between(Date.new(2026, 1, 1), Date.new(2026, 9, 30))
  end

  test "yearly rule clamps Feb 29 outside leap years" do
    schedule = build_schedule(rules: [ rule(frequency: "yearly", month_of_year: 2, day_of_month: 29) ])
    assert_equal [ Date.new(2024, 2, 29), Date.new(2025, 2, 28), Date.new(2026, 2, 28) ],
                 schedule.occurrences_between(Date.new(2024, 1, 1), Date.new(2026, 12, 31))
  end

  test "weekend adjust before moves saturday and sunday to friday" do
    # Aug 15 2026 is a Saturday, Sep 15 a Tuesday.
    schedule = build_schedule(rules: [ rule(frequency: "monthly", day_of_month: 15) ], weekend_adjust: "before")
    assert_equal [ Date.new(2026, 8, 14), Date.new(2026, 9, 15) ],
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 30))
  end

  test "weekend adjust after moves to monday and skip drops the occurrence" do
    after_schedule = build_schedule(rules: [ rule(frequency: "monthly", day_of_month: 15) ], weekend_adjust: "after")
    assert_equal [ Date.new(2026, 8, 17), Date.new(2026, 9, 15) ],
                 after_schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 30))

    skip_schedule = build_schedule(rules: [ rule(frequency: "monthly", day_of_month: 15) ], weekend_adjust: "skip")
    assert_equal [ Date.new(2026, 9, 15) ],
                 skip_schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 30))
  end

  test "weekend adjustment near the window edge cannot lose an occurrence" do
    # Due Sat Aug 1 2026, adjusted back to Fri Jul 31: a July-only query finds
    # it, an August-only query does not.
    schedule = build_schedule(rules: [ rule(frequency: "monthly", day_of_month: 1) ], weekend_adjust: "before")
    assert_includes schedule.occurrences_between(Date.new(2026, 7, 1), Date.new(2026, 7, 31)), Date.new(2026, 7, 31)
    assert_not_includes schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 8, 31)), Date.new(2026, 7, 31)
  end

  test "end_on truncates the series" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15) ],
      end_mode: "on_date", end_on: Date.new(2026, 9, 30)
    )
    assert_equal [ Date.new(2026, 8, 15), Date.new(2026, 9, 15) ],
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 12, 31))
    assert_nil schedule.first_occurrence_after(Date.new(2026, 9, 15))
  end

  test "after_count caps lifetime occurrences from the anchor" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15) ],
      anchor_date: Date.new(2026, 8, 15),
      end_mode: "after_count", end_after_count: 3
    )
    assert_equal [ Date.new(2026, 8, 15), Date.new(2026, 9, 15), Date.new(2026, 10, 15) ],
                 schedule.occurrences_between(Date.new(2026, 1, 1), Date.new(2027, 12, 31))
    assert_equal Date.new(2026, 10, 15), schedule.first_occurrence_after(Date.new(2026, 9, 15))
    assert_nil schedule.first_occurrence_after(Date.new(2026, 10, 15))
  end

  test "a future-anchored after_count plan stays out of windows that end before it" do
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15) ],
      anchor_date: Date.new(2026, 10, 15),
      end_mode: "after_count", end_after_count: 3
    )
    assert_equal [], schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 9, 30)),
      "the anchor occurrence is beyond the window and must not leak into it"
    assert_equal [ Date.new(2026, 10, 15) ],
                 schedule.occurrences_between(Date.new(2026, 8, 1), Date.new(2026, 10, 31))
  end

  test "after_count counts an anchor occurrence adjusted before the anchor date" do
    # Aug 15 2026 is a Saturday, so "before" moves the first payment to
    # Friday Aug 14 -- a day before the anchor. It is still the plan's first
    # occurrence; a three-payment plan must not materialize a November one.
    schedule = build_schedule(
      rules: [ rule(frequency: "monthly", day_of_month: 15) ],
      anchor_date: Date.new(2026, 8, 15),
      weekend_adjust: "before",
      end_mode: "after_count", end_after_count: 3
    )

    assert_equal [ Date.new(2026, 8, 14), Date.new(2026, 9, 15), Date.new(2026, 10, 15) ],
                 schedule.occurrences_between(Date.new(2026, 1, 1), Date.new(2027, 12, 31))
    assert_nil schedule.first_occurrence_after(Date.new(2026, 10, 15)),
      "a fourth occurrence never exists under a three-payment plan"
  end

  test "first_occurrence_after survives long weekend-skip droughts" do
    # A yearly bill due on a Saturday with skip adjustment has no occurrence
    # that year at all; the search must roll to the next non-weekend year.
    schedule = build_schedule(
      rules: [ rule(frequency: "yearly", month_of_year: 8, day_of_month: 15) ],
      weekend_adjust: "skip"
    )
    # Aug 15: 2026 Saturday (skipped), 2027 Sunday (skipped), 2028 Tuesday.
    assert_equal Date.new(2028, 8, 15), schedule.first_occurrence_after(Date.new(2026, 1, 1))
  end

  test "occurrences_per_year sums rule cadences" do
    semimonthly = build_schedule(rules: [
      rule(frequency: "monthly", day_of_month: 1),
      rule(frequency: "monthly", day_of_month: 15)
    ])
    assert_in_delta 24.0, semimonthly.occurrences_per_year, 0.001

    biweekly = build_schedule(rules: [ rule(frequency: "weekly", weekday: 5, interval: 2) ],
                              anchor_date: Date.new(2026, 8, 7))
    assert_in_delta 26.09, biweekly.occurrences_per_year, 0.01
  end

  test "legacy shims fall through to correct semantics for non-monthly shapes" do
    schedule = build_schedule(rules: [ rule(frequency: "weekly", weekday: 5) ])
    # Aug 13 2026 is a Thursday; the next Friday is the 14th -- no
    # jump-a-whole-period quirk for rule shapes the old code never handled.
    assert_equal Date.new(2026, 8, 14), schedule.next_occurrence_after(Date.new(2026, 8, 13))
  end

  test "interval rules refuse to build without an anchor" do
    assert_raises(ArgumentError) do
      build_schedule(rules: [ rule(frequency: "weekly", weekday: 5, interval: 2) ])
    end
  end

  test "cycle_for works across rule shapes" do
    schedule = build_schedule(rules: [
      rule(frequency: "monthly", day_of_month: 1),
      rule(frequency: "monthly", day_of_month: 15)
    ])
    cycle = schedule.cycle_for(Date.new(2026, 8, 10))
    assert_equal Date.new(2026, 8, 1), cycle.begin
    assert_equal Date.new(2026, 8, 15), cycle.end
  end


  # The legacy shim builds Date.new from expected_day_of_month, and a nil there
  # raises TypeError past the ArgumentError rescue.
  test "a rules-backed schedule with no legacy day never enters the shim" do
    schedule = build_schedule(rules: [ rule(frequency: "monthly", day_of_month: 12) ])

    assert_nothing_raised do
      assert_equal 12, schedule.next_occurrence_from_today.day
    end
  end

  private
    def rule(frequency:, interval: 1, day_of_month: nil, weekday: nil, weekday_ordinal: nil, month_of_year: nil)
      RecurringTransaction::Schedule::Rule.new(
        frequency:, interval:, day_of_month:, weekday:, weekday_ordinal:, month_of_year:
      )
    end

    def build_schedule(rules:, anchor_date: nil, weekend_adjust: "none", end_mode: "never", end_on: nil, end_after_count: nil)
      RecurringTransaction::Schedule.new(
        expected_day_of_month: nil,
        rules:, anchor_date:, weekend_adjust:, end_mode:, end_on:, end_after_count:
      )
    end

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
      # Name-keyed with a unique name: identity no longer includes amount, so
      # reusing the fixture's merchant would collide with netflix_subscription.
      recurring = build_recurring(merchant: nil, name: "Window test bill #{overrides[:expected_day_of_month]}", **overrides)
      recurring.save!
      recurring
    end

    def create_matching_entry(recurring, date:)
      @account.entries.create!(
        date: date,
        amount: recurring.amount,
        currency: recurring.currency,
        name: recurring.name || "Netflix charge",
        entryable: Transaction.new(merchant_id: recurring.merchant_id)
      )
    end
end
