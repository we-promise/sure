require "test_helper"

class Loan::RepaymentPlanTest < ActiveSupport::TestCase
  # C6: an extra repayment takes effect at the end of its OWN effective date.
  # Payment dates never defer it. The earlier draft of this rule ("applies at
  # the next scheduled payment") contradicts daily accrual -- deferring would
  # charge interest the borrower did not owe between the two dates.
  test "a one-off applies on its own date, not at the next payment" do
    repayment = build_one_off(amount: 1_000, on: Date.new(2026, 3, 15))
    plan = Loan::RepaymentPlan.new([ repayment ])

    inside = plan.change_points(Date.new(2026, 3, 1), Date.new(2026, 4, 1))

    assert_equal [ Date.new(2026, 3, 15) ], inside.map { |point| point[:date] }
    assert_equal BigDecimal("1000"), inside.sole[:amount]
  end

  # The simulator's normaliser matches dates inclusively at BOTH ends, and it
  # walks contiguous periods. A repayment on a period boundary would therefore
  # be handed to the period that closes on it and the one that opens on it, and
  # applied twice -- a delta double-counted. The plan is half-open so each date
  # lands in exactly one period: the one that opens on it.
  test "a repayment on a period boundary is counted once, in the period that opens on it" do
    repayment = build_one_off(amount: 1_000, on: Date.new(2026, 3, 15))
    plan = Loan::RepaymentPlan.new([ repayment ])

    closing = plan.change_points(Date.new(2026, 2, 15), Date.new(2026, 3, 15))
    opening = plan.change_points(Date.new(2026, 3, 15), Date.new(2026, 4, 15))

    assert_empty closing, "the period CLOSING on the date must not claim it"
    assert_equal 1, opening.size, "the period OPENING on the date must claim it"
  end

  # FR-303: recurrence materialises to exact dates, never a monthly equivalent.
  # $500 weekly is 52 reductions of $500, not 12 of $2,166.67 -- and the
  # interest difference between those is the reason someone models weekly.
  test "a weekly repayment produces 52 dated reductions a year, not 12" do
    repayment = build_recurring(amount: 500, frequency: "weekly", starts_on: Date.new(2026, 1, 5))

    points = Loan::RepaymentPlan.new([ repayment ]).change_points(Date.new(2026, 1, 1), Date.new(2027, 1, 1))

    assert_equal 52, points.size
    assert_equal BigDecimal("26000"), points.sum { |point| point[:amount] }
    assert_not_equal 12, points.size, "a monthly equivalent would be 12 points and the wrong interest"
  end

  test "each cadence materialises at its own rhythm" do
    { "weekly" => 52, "fortnightly" => 26, "monthly" => 12, "quarterly" => 4, "yearly" => 1 }.each do |frequency, expected|
      repayment = build_recurring(amount: 100, frequency: frequency, starts_on: Date.new(2026, 1, 5))

      points = Loan::RepaymentPlan.new([ repayment ]).change_points(Date.new(2026, 1, 1), Date.new(2027, 1, 1))

      assert_equal expected, points.size, "#{frequency} must produce #{expected} points in a year"
    end
  end

  test "a recurring repayment stops at its end date" do
    repayment = build_recurring(amount: 100, frequency: "monthly",
      starts_on: Date.new(2026, 1, 5), ends_on: Date.new(2026, 6, 5))

    points = Loan::RepaymentPlan.new([ repayment ]).change_points(Date.new(2026, 1, 1), Date.new(2027, 1, 1))

    assert_equal 6, points.size
    assert_equal Date.new(2026, 6, 5), points.last[:date]
  end

  test "repayments falling on one date are summed rather than losing one another" do
    date = Date.new(2026, 3, 15)
    plan = Loan::RepaymentPlan.new([ build_one_off(amount: 100, on: date), build_one_off(amount: 250, on: date) ])

    points = plan.change_points(Date.new(2026, 3, 1), Date.new(2026, 4, 1))

    assert_equal 1, points.size
    assert_equal BigDecimal("350"), points.sole[:amount]
  end

  test "an empty or inverted window yields nothing rather than raising" do
    plan = Loan::RepaymentPlan.new([ build_one_off(amount: 100, on: Date.new(2026, 3, 15)) ])

    assert_empty plan.change_points(Date.new(2026, 4, 1), Date.new(2026, 3, 1))
    assert_empty plan.change_points(Date.new(2026, 3, 1), Date.new(2026, 3, 1))
    assert_empty Loan::RepaymentPlan.new(nil).change_points(Date.new(2026, 1, 1), Date.new(2027, 1, 1))
  end

  # cubic, #83. Half-open windows put every date in exactly one period -- except
  # the final payment date, which has no period opening on it and fell through
  # all of them. Walked the way Simulator walks, because the defect only appears
  # across the whole schedule, never in a single call.
  test "a repayment on the final payment date lands in exactly one window" do
    dates = (1..12).map { |month| Date.new(2026, 1, 5) >> month }
    plan = Loan::RepaymentPlan.new([ build_one_off(amount: 5_000, on: dates.last) ], closes_on: dates.last)

    assert_equal 1, occurrences_across(plan, Date.new(2026, 1, 5), dates),
      "a repayment on the last payment date must still be applied, not silently dropped"
  end

  test "a repayment on an interior payment date lands in exactly one window" do
    dates = (1..12).map { |month| Date.new(2026, 1, 5) >> month }
    plan = Loan::RepaymentPlan.new([ build_one_off(amount: 5_000, on: dates[3]) ], closes_on: dates.last)

    assert_equal 1, occurrences_across(plan, Date.new(2026, 1, 5), dates),
      "counted twice would double-apply the repayment; counted zero times would lose it"
  end

  # The resolver is called once per payment period. A recurrence anchored on the
  # window rather than on the row fires once per window -- so a quarterly
  # repayment became a monthly one.
  test "a quarterly repayment stays quarterly when resolved period by period" do
    dates = (1..12).map { |month| Date.new(2026, 1, 5) >> month }
    repayment = build_recurring(amount: 250, frequency: "quarterly", starts_on: Date.new(2026, 2, 5))
    plan = Loan::RepaymentPlan.new([ repayment ], closes_on: dates.last)

    assert_equal 4, occurrences_across(plan, Date.new(2026, 1, 5), dates),
      "resolving per period must not multiply a quarterly cadence into a monthly one"
  end

  private

    # Every change point the simulator would see, walking contiguous windows.
    def occurrences_across(plan, start_date, payment_dates)
      previous = start_date
      payment_dates.sum do |payment_date|
        count = plan.change_points(previous, payment_date).size
        previous = payment_date
        count
      end
    end

    def build_one_off(amount:, on:)
      LoanExtraRepayment.new(kind: "one_off", amount: amount, occurs_on: on)
    end

    def build_recurring(amount:, frequency:, starts_on:, ends_on: nil)
      LoanExtraRepayment.new(kind: "recurring", amount: amount, frequency: frequency,
        interval: 1, starts_on: starts_on, ends_on: ends_on)
    end
end
