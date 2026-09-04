require "test_helper"
require "ostruct"

class BillsHelperTest < ActionView::TestCase
  # bills_match_reasons formats one money value, and format_money lives in
  # ApplicationHelper rather than this module.
  include ApplicationHelper

  # The matcher has always stored WHY it matched something, in match_signals.
  # Nothing rendered it, so the app showed a bare percentage instead of the
  # facts the percentage is made of.
  test "the signals behind an exact match read as plain reasons" do
    reasons = bills_match_reasons(
      { merchant: 0.40, amount: 0.30, date: 0.20, account: 0.10 },
      currency: "USD",
      expected: BigDecimal("6.44"),
      actual: BigDecimal("6.44"),
      due_on: Date.new(2026, 7, 31),
      paid_on: Date.new(2026, 7, 31)
    )

    assert_equal [
      I18n.t("bills.match.same_merchant"),
      I18n.t("bills.match.exact_amount"),
      I18n.t("bills.match.due_date")
    ], reasons
  end

  # signals[:account] is a constant 0.10 on every candidate, because
  # identity_matches? has already rejected everything on another account. A
  # reason that never distinguishes anything is decoration.
  test "the account signal is never rendered as a reason" do
    reasons = bills_match_reasons(
      { merchant: 0.40, amount: 0.30, date: 0.20, account: 0.10 },
      currency: "USD", expected: 10, actual: 10,
      due_on: Date.current, paid_on: Date.current
    )

    assert_no_match(/account/i, reasons.join(" "))
  end

  test "an inexact amount names the difference, and a nearby date names the gap" do
    reasons = bills_match_reasons(
      { name: 0.35, amount: 0.22, date: 0.14 },
      currency: "USD",
      expected: BigDecimal("14.99"),
      actual: BigDecimal("13.27"),
      due_on: Date.new(2026, 7, 31),
      paid_on: Date.new(2026, 7, 30)
    )

    assert_includes reasons, I18n.t("bills.match.name_matches")
    assert_includes reasons, I18n.t("bills.match.amount_off", amount: "$1.72")
    assert_includes reasons, I18n.t("bills.match.days_before", count: 1)
  end

  test "a date after the due date reads as after" do
    reasons = bills_match_reasons(
      { date: 0.10 },
      currency: "USD",
      due_on: Date.new(2026, 7, 31),
      paid_on: Date.new(2026, 8, 3)
    )

    assert_equal [ I18n.t("bills.match.days_after", count: 3) ], reasons
  end

  # A suggestion's entry FK nullifies rather than cascades, so the review queue
  # can hold an allocation with no entry behind it. An unguarded subtraction
  # would raise on the one screen this helper exists to improve.
  test "a signal with no figures behind it is skipped rather than raising" do
    assert_nothing_raised do
      reasons = bills_match_reasons({ merchant: 0.40, amount: 0.30, date: 0.20 }, currency: "USD")

      assert_equal [ I18n.t("bills.match.same_merchant") ], reasons
    end
  end

  test "string keys out of jsonb work the same as symbols" do
    reasons = bills_match_reasons(
      { "merchant" => 0.40, "amount" => 0.30 },
      currency: "USD", expected: 5, actual: 5
    )

    assert_equal [
      I18n.t("bills.match.same_merchant"),
      I18n.t("bills.match.exact_amount")
    ], reasons
  end

  test "no signals at all yields no reasons" do
    assert_empty bills_match_reasons(nil, currency: "USD")
    assert_empty bills_match_reasons({}, currency: "USD")
  end

  # The bar exists to show a paycheck divided three ways. If the segments do
  # not carry the three amounts the card states in words, it is decoration
  # sitting where an explanation should be.
  test "a healthy period divides into due, reserved and safe" do
    period = build_period(income: 1200, due: 357.48, reserved: 338.12)

    assert_equal [ :due, :reserved, :safe ], paycheck_allocation_segments(period).map(&:first)
    assert_in_delta 29.79, paycheck_allocation_segments(period).first.last, 0.01
  end

  # Rounding three shares to two places can leave the track a hair short, and
  # a fully allocated paycheck showing a sliver of empty bar is the one thing
  # this bar must never say.
  test "segments always add up to exactly 100" do
    [ [ 1200, 357.48, 338.12 ], [ 1000, 333.33, 333.33 ], [ 999.99, 333.33, 0 ] ].each do |income, due, reserved|
      segments = paycheck_allocation_segments(build_period(income: income, due: due, reserved: reserved))

      assert_equal 100, segments.sum(&:last), "#{income}/#{due}/#{reserved} did not fill the track"
    end
  end

  # Dividing a short period three ways would draw a safe slice out of money
  # that is not there.
  test "a short period reads as covered and short, never as safe" do
    period = build_period(income: 500, due: 400, reserved: 300)

    segments = paycheck_allocation_segments(period)

    assert_equal [ :covered, :short ], segments.map(&:first)
    assert_equal 100, segments.sum(&:last)
    assert_in_delta 71.43, segments.first.last, 0.01
  end

  test "a window with no income has no bar at all" do
    assert_empty paycheck_allocation_segments(build_period(income: 0, due: 28.71, reserved: 695.62))
  end

  test "a zero part is dropped rather than drawn as a hairline" do
    segments = paycheck_allocation_segments(build_period(income: 1200, due: 0, reserved: 338.12))

    assert_equal [ :reserved, :safe ], segments.map(&:first)
  end

  # "Paycheck" is an assumption. A declared income series can be a pension or
  # an invoice, and the user's own setup already names it.
  test "a period is headed by the income that opens it" do
    period = build_period(income: 1200, due: 0, reserved: 0, sources: [ "Frito Lay" ])

    assert_equal "#{I18n.l(period.starts_on, format: :short)} · Frito Lay", paycheck_period_heading(period),
      "the date leads, because the timeline is read down its date anchors"
  end

  test "two sources on one day are counted, not merged into one name" do
    period = build_period(income: 1400, due: 0, reserved: 0, sources: [ "Frito Lay", "Side work" ])

    assert_match(/2 income sources/, paycheck_period_heading(period))
  end


  # Reported from live use: a Twitch charge showed "$11.99 of $11.99 paid" and
  # "Overdue by 20 days" on the same line. The label only ever read dates, so a
  # cycle settled after its due date stayed "overdue" forever.
  test "a settled cycle is not overdue" do
    occurrence = build_occurrence(due_on: 20.days.ago.to_date, status: "paid")

    label = occurrence_due_label(occurrence)

    assert_match(/was due/i, label)
    assert_no_match(/overdue/i, label, "a paid cycle cannot also be late")
  end

  test "skipped and missed cycles read the same way" do
    %w[skipped missed].each do |status|
      occurrence = build_occurrence(due_on: 20.days.ago.to_date, status: status)

      assert_no_match(/overdue/i, occurrence_due_label(occurrence),
        "a #{status} cycle is closed, so it is not still running late")
    end
  end

  test "an open cycle past its due date is still overdue" do
    occurrence = build_occurrence(due_on: 20.days.ago.to_date, status: "scheduled")

    assert_match(/overdue/i, occurrence_due_label(occurrence),
      "the overdue case must survive: that is the one the label exists for")
  end


  # derived_state only calls a cycle overdue once its grace has run out, and
  # the overview and get_bills both honour that. This label read the raw date,
  # so the screen said Overdue by 1 day about a bill the assistant correctly
  # called due.
  test "a cycle inside its grace period is not labelled overdue" do
    occurrence = build_occurrence(due_on: Date.current - 1, status: "scheduled")
    assert_equal :due, occurrence.derived_state, "precondition: still inside grace"

    label = occurrence_due_label(occurrence)

    assert_no_match(/overdue/i, label)
    assert_match(/due/i, label)
  end

  test "a cycle past its grace is still labelled overdue" do
    occurrence = build_occurrence(due_on: Date.current - 30, status: "scheduled")
    assert_equal :overdue, occurrence.derived_state, "precondition: grace exhausted"

    assert_match(/overdue/i, occurrence_due_label(occurrence))
  end

  # --- Prepared-data helpers extracted from the templates, so the section,
  # pulse, detail and paycheck views render precomputed values. ---

  test "ambiguous row keys mark only genuine collisions" do
    twin_a = stub_occurrence("Twitch", 5.99, id: "a1")
    twin_b = stub_occurrence("Twitch", 5.99, id: "a2")
    other_tier = stub_occurrence("Twitch", 11.99, id: "b")

    keys = bills_ambiguous_row_keys([ twin_a, twin_b, other_tier ])

    assert_includes keys, [ "Twitch", 5.99 ]
    assert_not_includes keys, [ "Twitch", 11.99 ]
  end

  test "pay period markers land on the first row of each period with its summed total" do
    period = OpenStruct.new(starts_on: Date.new(2026, 9, 1), ends_on: Date.new(2026, 9, 14))
    first_inside = stub_occurrence("Rent", 2150, id: "one", due_on: Date.new(2026, 9, 2))
    second_inside = stub_occurrence("Power", 80, id: "two", due_on: Date.new(2026, 9, 10))
    outside = stub_occurrence("Later", 10, id: "three", due_on: Date.new(2026, 9, 20))

    markers = bills_pay_period_markers([ first_inside, second_inside, outside ], [ period ])

    assert_equal [ "one" ], markers.keys
    assert_equal 2230, markers["one"][:due_total]
    assert_equal period, markers["one"][:period]
  end

  test "no pay periods means no markers" do
    occurrence = stub_occurrence("Rent", 1, id: "x", due_on: Date.current)

    assert_empty bills_pay_period_markers([ occurrence ], [])
  end

  test "month progress divides paid, overdue and upcoming out of one total" do
    progress = bills_month_progress(paid: 50, remaining: 50, overdue: 25)

    assert_equal 100.0, progress[:total]
    assert_in_delta 50.0, progress[:paid_pct]
    assert_in_delta 25.0, progress[:overdue_pct]
    assert_in_delta 25.0, progress[:upcoming_pct]
  end

  test "an empty month draws no bar" do
    progress = bills_month_progress(paid: nil, remaining: nil, overdue: nil)

    assert_equal 0.0, progress[:total]
    assert_equal 0, progress[:paid_pct]
  end

  test "overdue money never claims more of the bar than what remains" do
    progress = bills_month_progress(paid: 80, remaining: 20, overdue: 500)

    assert_in_delta 20.0, progress[:overdue_pct]
    assert_in_delta 0.0, progress[:upcoming_pct]
  end

  test "matcher hints strip blanks and cast the tolerance" do
    series = OpenStruct.new(matcher_hints: { "name_aliases" => [ "PEPSICO", "" ], "learned_tolerance_pct" => "7.5" })

    hints = bills_matcher_hints(series)

    assert_equal [ "PEPSICO" ], hints[:aliases]
    assert_equal 7.5, hints[:learned_pct]
  end

  test "plan sections split the bridge from the timeline and pick the warning state" do
    short_bridge = build_period(income: 0, due: 400, reserved: 0, leading: true, cash_on_hand: BigDecimal("100"))
    period = build_period(income: 1200, due: 300, reserved: 100)

    sections = paycheck_plan_sections([ short_bridge, period ])

    assert_equal [ period ], sections[:periods]
    assert_equal short_bridge, sections[:shortfall]
    assert_nil sections[:bridge_note]
  end

  test "a covered bridge with items becomes the quiet note, not the warning" do
    covered = build_period(income: 0, due: 50, reserved: 0, leading: true,
                           cash_on_hand: BigDecimal("500"), items: [ :a_bill ])

    sections = paycheck_plan_sections([ covered ])

    assert_nil sections[:shortfall]
    assert_equal covered, sections[:bridge_note]
  end

  test "no plan yields empty sections" do
    assert_empty paycheck_plan_sections(nil)
  end

  private

    def stub_occurrence(name, amount, id:, due_on: Date.current)
      OpenStruct.new(
        id: id,
        due_on: due_on,
        resolved_expected_amount: amount,
        recurring_transaction: OpenStruct.new(display_name: name)
      )
    end

    def build_occurrence(due_on:, status:)
      family = users(:family_admin).family
      series = family.recurring_transactions.create!(
        name: "Twitch #{status} #{due_on}", account: accounts(:depository),
        amount: 11.99, currency: "USD", expected_day_of_month: due_on.day,
        status: "active", bill_type: "subscription", manual: true,
        dedup_scope: "twitch-#{status}-#{due_on}",
        last_occurrence_date: due_on, next_expected_date: due_on
      )
      series.recurring_occurrences.destroy_all
      series.recurring_occurrences.create!(
        family: family, original_due_on: due_on, due_on: due_on,
        currency: "USD", expected_amount: 11.99, status: status,
        closed_at: (status == "scheduled" ? nil : Time.current)
      )
    end
    def build_period(income:, due:, reserved:, sources: [ "Payroll" ], leading: false, cash_on_hand: nil, items: [])
      obligations = BigDecimal(due.to_s) + BigDecimal(reserved.to_s)

      RecurringTransaction::PaycheckPlanner::Period.new(
        starts_on: Date.new(2026, 8, 19),
        ends_on: Date.new(2026, 8, 25),
        income: BigDecimal(income.to_s),
        income_sources: sources,
        items: items,
        due_total: BigDecimal(due.to_s),
        reserved_total: BigDecimal(reserved.to_s),
        obligation_total: obligations,
        remaining: BigDecimal(income.to_s) - obligations,
        leading: leading,
        final: false,
        cash_on_hand: cash_on_hand
      )
    end
end
