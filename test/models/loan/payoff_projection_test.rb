require "test_helper"

class Loan::PayoffProjectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # Builds a fixed-rate loan whose original balance is pinned via an explicit
  # opening_anchor valuation (so `Loan#original_balance` stays fixed even
  # after we later mutate `account.balance` to simulate the "current, actual"
  # position). start_date defaults to today so every persisted amortization
  # row is naturally in the future relative to `Date.current`.
  def build_loan(balance:, interest_rate: 3.5, term_months: 360, start_date: Date.current, rate_type: "fixed")
    account = Account.create! \
      family: @family,
      name: "Test Loan #{SecureRandom.hex(4)}",
      balance: balance,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: interest_rate,
        term_months: term_months,
        rate_type: rate_type,
        start_date: start_date
      )

    account.entries.create!(
      name: "Starting balance",
      amount: balance,
      currency: "USD",
      date: start_date,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    account.loan.tap(&:ensure_amortization_schedule_current!)
  end

  # Regression for the #35 x #39 interaction.
  #
  # `applicable?` used to require `loan.amortizations.exists?` and compared
  # against rows read straight from that association. That worked only because
  # the Schedule tab rebuilt the schedule inside the request. Once the read path
  # stopped writing (#39), a loan with no persisted rows silently lost its
  # projection card -- no error, just a missing feature.
  #
  # The projection now reads AmortizationSchedule#display_rows, the same source
  # as the table and the summary cards.
  test "projects without persisted rows, and agrees with the persisted result once they exist" do
    loan = build_loan(balance: 500_000)
    loan.account.update!(balance: 450_000)

    with_rows = loan.payoff_projection
    assert with_rows.applicable?, "test setup must produce an applicable projection"
    expected_date = with_rows.payoff_date
    expected_saved = with_rows.interest_saved

    loan.amortizations.delete_all
    loan.reload

    assert_empty loan.amortizations, "the persisted rows must be gone for this to prove anything"

    without_rows = loan.payoff_projection
    assert without_rows.applicable?,
      "a projection is a display calculation and must not depend on a write having happened (#39)"
    assert_equal expected_date, without_rows.payoff_date
    assert_equal expected_saved, without_rows.interest_saved
  end

  test "projecting does not persist amortization rows" do
    loan = build_loan(balance: 500_000)
    loan.account.update!(balance: 450_000)
    loan.amortizations.delete_all
    loan.reload

    assert_no_difference -> { LoanAmortization.count } do
      loan.payoff_projection.payoff_date
    end
  end

  test "matches the original schedule (within a rounding-driven cleanup payment) when the current balance equals the original balance" do
    loan = build_loan(balance: 500000)

    projection = loan.payoff_projection

    # The original schedule forces its (known-in-advance) final payment to
    # exactly clear the balance, adjusting that payment's amount. This
    # projection doesn't know its final period in advance -- it keeps paying
    # the constant level payment and only adjusts once a period's payment
    # would otherwise overshoot -- so an unchanged balance can still trail by
    # one small "cleanup" payment after 360 periods of accumulated monthly
    # rounding. That's a real, tiny artifact of two independently-terminated
    # simulations, not a meaningful difference.
    assert projection.applicable?
    assert projection.months_saved.between?(-1, 0)
    assert projection.interest_saved.abs < 1
  end

  test "projects a sooner payoff and positive interest saved when ahead of schedule" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 450000) # extra $50k paid toward principal

    projection = loan.payoff_projection

    assert projection.applicable?
    assert projection.months_saved > 0
    assert projection.interest_saved > 0
    assert projection.payoff_date < loan.amortization_schedule.payoff_date
    assert_equal loan.amortization_schedule.monthly_payment, projection.monthly_payment
  end

  test "projects a later payoff and negative interest saved when behind schedule" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 550000) # owes more than originally contracted

    projection = loan.payoff_projection

    assert projection.applicable?
    assert projection.months_saved < 0
    assert projection.interest_saved < 0
  end

  test "not applicable when the current balance is fully paid off" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 0)

    projection = loan.payoff_projection

    assert_not projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_nil projection.months_saved
    assert_nil projection.interest_saved
    assert_equal [], projection.payments
  end

  test "projects a variable rate loan using rates effective in each payment period" do
    loan = build_loan(balance: 500000, rate_type: "variable")
    loan.ensure_amortization_schedule_current!
    payment_dates = loan.amortizations.where("payment_date > ?", Date.current).ordered.pluck(:payment_date)
    loan.update!(variable_rate_schedule: {
      payment_dates[1].iso8601 => 4.5,
      payment_dates[3].iso8601 => 5.5
    })
    loan.account.update!(balance: 450000)

    projection = loan.payoff_projection

    assert projection.applicable?
    assert_equal [ BigDecimal("3.5"), BigDecimal("4.5"), BigDecimal("4.5"), BigDecimal("5.5"), BigDecimal("5.5") ],
      projection.payments.first(5).map { |payment| payment[:interest_rate] }
    assert projection.payoff_date
  end

  test "extra-payment projection applies recorded variable rates while holding the repayment" do
    loan = build_loan(balance: 500000, rate_type: "variable")
    payment_dates = loan.amortizations.where("payment_date > ?", Date.current).ordered.pluck(:payment_date)
    loan.update!(variable_rate_schedule: {
      payment_dates[1].iso8601 => 4.5,
      payment_dates[3].iso8601 => 5.5
    })
    loan.account.update!(balance: 450000)
    extra_payment = Loan::PayoffProjection.monthly_equivalent(
      amount: 200,
      frequency: "monthly",
      currency: "USD"
    )

    projection = Loan::PayoffProjection.new(loan, extra_payment: extra_payment)

    assert projection.applicable?
    assert_equal [ BigDecimal("3.5"), BigDecimal("4.5"), BigDecimal("4.5"), BigDecimal("5.5"), BigDecimal("5.5") ],
      projection.payments.first(5).map { |payment| payment[:interest_rate] }
    expected_payment = loan.amortization_schedule.monthly_payment.amount + extra_payment.amount
    assert projection.payments.first(5).all? { |payment| payment[:payment_amount] == expected_payment },
      "recorded rate changes must not replace the held repayment in the what-if projection"
  end

  test "not applicable when the fixed payment no longer covers interest at the current balance" do
    loan = build_loan(balance: 500000)
    # Monthly payment (~$2245.22) no longer covers interest once the balance
    # is high enough: 2245.22 / (3.5% / 12) ~= 769,790.
    loan.account.update!(balance: 800000)

    assert_not loan.payoff_projection.applicable?
  end

  test "all persisted original payments are in the future for a loan starting today" do
    loan = build_loan(balance: 500000)
    loan.payoff_projection # triggers ensure_amortization_schedule_current!

    assert_equal 360, loan.amortizations.where("payment_date > ?", Date.current).count
  end

  test "zero interest rate projects a straight-line payoff" do
    loan = build_loan(balance: 120000, interest_rate: 0, term_months: 120)
    loan.account.update!(balance: 100000)

    projection = loan.payoff_projection

    assert projection.applicable?
    assert projection.months_saved > 0
    assert_equal BigDecimal("0"), projection.total_interest.amount
  end

  # Regression: the simulation used to start at Date.current.next_month,
  # which uses *today's* day-of-month rather than the loan's actual payment
  # anchor day. A loan whose payments fall on the 15th, viewed on any other
  # day, would get every projected date wrong.
  test "anchors the first projected payment on the loan's actual next scheduled payment date, not today's day-of-month" do
    # Pinned: if this ran on the 15th of any month, start_date's day-15
    # anchor would coincide with Date.current.next_month, defeating the
    # "real anchor mismatch" guard below and the point of the regression.
    travel_to Date.new(2026, 3, 20) do
      start_date = 2.years.ago.to_date.change(day: 15)
      loan = build_loan(balance: 500000, start_date: start_date)
      loan.ensure_amortization_schedule_current!
      loan.account.update!(balance: 450000)

      next_scheduled_date = loan.amortizations.where("payment_date > ?", Date.current).ordered.first.payment_date
      assert_not_equal Date.current.next_month, next_scheduled_date, "test setup should exercise a real anchor mismatch"

      projection = loan.payoff_projection

      assert_equal next_scheduled_date, projection.payments.first[:payment_date]
    end
  end

  # Regression: a payment that technically covers first-period interest but
  # only barely (a real, if unusual, input -- e.g. a much larger balance
  # than originally contracted) can take far longer than the iteration cap
  # to actually reach zero. The old code let the loop exit early and still
  # reported the last simulated date as a "payoff" -- a fabricated result.
  test "is not applicable when the simulation does not converge within the iteration cap" do
    loan = build_loan(balance: 100000, interest_rate: 5.0, term_months: 12)
    payment = loan.amortization_schedule.monthly_payment.amount
    monthly_rate = BigDecimal("5.0") / 100 / 12
    threshold_balance = payment / monthly_rate # balance at which payment == first-period interest

    non_converging_balance = (threshold_balance * BigDecimal("0.995")).round(2)
    loan.account.update!(balance: non_converging_balance)

    # Payment still exceeds first-period interest -- not "unamortizable" by
    # that cheaper check -- but the payoff genuinely takes more than
    # MAX_ITERATIONS_MULTIPLIER * term_months periods to reach zero.
    first_interest = non_converging_balance * monthly_rate
    assert payment > first_interest, "test setup should not trip the simpler unamortizable_payment? check"

    projection = loan.payoff_projection

    assert_not projection.applicable?
    assert_nil projection.payoff_date
    assert_nil projection.months_saved
    assert_nil projection.interest_saved
    assert_equal [], projection.payments
  end

  # Regression: Loan#payoff_projection is memoized; without invalidation, a
  # long-lived Loan instance kept returning a projection computed against
  # whatever balance was current the first time it was accessed.
  test "Loan#payoff_projection recomputes when the account balance changes within the object's lifetime" do
    loan = build_loan(balance: 500000)

    first = loan.payoff_projection
    assert_equal Money.new(500000, "USD"), first.current_balance

    loan.account.update!(balance: 450000)
    second = loan.payoff_projection

    assert_not_same first, second
    assert_equal Money.new(450000, "USD"), second.current_balance
  end

  test "an extra payment shortens the payoff and increases interest saved beyond the baseline" do
    loan = build_loan(balance: 500000)
    baseline = loan.payoff_projection

    boosted = Loan::PayoffProjection.new(
      loan,
      extra_payment: Loan::PayoffProjection.monthly_equivalent(amount: 200, frequency: "monthly", currency: "USD")
    )

    assert boosted.applicable?
    assert boosted.months_saved > baseline.months_saved
    assert boosted.interest_saved > baseline.interest_saved
    assert_equal baseline.monthly_payment + Money.new(200, "USD"), boosted.monthly_payment
  end

  test "a blank or zero extra payment behaves identically to no extra payment" do
    loan = build_loan(balance: 500000)
    baseline = loan.payoff_projection

    blank = Loan::PayoffProjection.new(loan, extra_payment: nil)
    zero = Loan::PayoffProjection.new(loan, extra_payment: Money.new(0, "USD"))

    assert_equal baseline.monthly_payment, blank.monthly_payment
    assert_equal baseline.monthly_payment, zero.monthly_payment
    assert_equal baseline.payoff_date, blank.payoff_date
    assert_equal baseline.payoff_date, zero.payoff_date
  end

  test "monthly_equivalent normalizes weekly and yearly amounts to a monthly figure" do
    assert_equal Money.new(BigDecimal("50") * 52 / 12, "USD"),
      Loan::PayoffProjection.monthly_equivalent(amount: 50, frequency: "weekly", currency: "USD")
    assert_equal Money.new(100, "USD"),
      Loan::PayoffProjection.monthly_equivalent(amount: 100, frequency: "monthly", currency: "USD")
    assert_equal Money.new(BigDecimal("1200") / 12, "USD"),
      Loan::PayoffProjection.monthly_equivalent(amount: 1200, frequency: "yearly", currency: "USD")
  end

  test "monthly_equivalent returns nil for a blank, zero, or non-numeric amount" do
    assert_nil Loan::PayoffProjection.monthly_equivalent(amount: nil, frequency: "monthly", currency: "USD")
    assert_nil Loan::PayoffProjection.monthly_equivalent(amount: "", frequency: "monthly", currency: "USD")
    assert_nil Loan::PayoffProjection.monthly_equivalent(amount: 0, frequency: "monthly", currency: "USD")
    assert_nil Loan::PayoffProjection.monthly_equivalent(amount: "not-a-number", frequency: "monthly", currency: "USD")
  end

  test "monthly_equivalent raises on an unsupported frequency" do
    assert_raises(ArgumentError) do
      Loan::PayoffProjection.monthly_equivalent(amount: 50, frequency: "fortnightly", currency: "USD")
    end
  end

  # Regression: eligible_for_extra_payment? is the coarser check used to
  # decide whether to show the what-if form -- it must stay true even when
  # the baseline (no-extra) #applicable? is false, since "the current
  # payment doesn't cover interest" is exactly when a user wants to model
  # paying more.
  test "eligible_for_extra_payment? is true even when the baseline payment doesn't cover interest" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 800000)

    assert_not loan.payoff_projection.applicable?
    assert Loan::PayoffProjection.eligible_for_extra_payment?(loan)
  end

  # INVERTED for #54. This asserted the fixed_rate? gate, which made
  # eligible_for_extra_payment? disagree with #applicable? after #12 removed the
  # same gate there -- a variable-rate loan got a projection and a chart but no
  # way to model paying extra, which is the loan where it matters most.
  test "eligible_for_extra_payment? is true for a variable rate loan" do
    loan = build_loan(balance: 500000, rate_type: "variable")

    assert Loan::PayoffProjection.eligible_for_extra_payment?(loan)
  end

  # The two must agree about rate type. They disagreed for two tranches.
  test "eligibility and applicability agree about rate type" do
    %w[fixed variable].each do |rate_type|
      loan = build_loan(balance: 500000, rate_type: rate_type)
      loan.account.update!(balance: 450000)

      assert_equal loan.payoff_projection.applicable?,
        Loan::PayoffProjection.eligible_for_extra_payment?(loan),
        "#{rate_type}: neither may gate on rate type without the other (#54)"
    end
  end

  test "eligible_for_extra_payment? is false when the balance is already zero" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 0)

    assert_not Loan::PayoffProjection.eligible_for_extra_payment?(loan)
  end

  # BigDecimal parses these without raising, and both slip past a `<= 0` guard:
  # every comparison with NaN is false, and Infinity is genuinely positive.
  # Money.new accepts either, so the value would reach Loan::Simulator.
  test "monthly_equivalent rejects non-finite amounts" do
    %w[NaN Infinity -Infinity].each do |raw|
      assert_nil Loan::PayoffProjection.monthly_equivalent(amount: raw, frequency: "monthly", currency: "USD"),
        "#{raw} must not become a Money amount that can reach the simulator"
    end
  end

  test "monthly_equivalent still accepts ordinary amounts" do
    money = Loan::PayoffProjection.monthly_equivalent(amount: "50", frequency: "weekly", currency: "USD")

    assert_not_nil money
    assert_predicate money.amount, :finite?
    assert_in_delta 216.67, money.amount.to_f, 0.01, "50/week is 50 * 52 / 12 monthly-equivalent"
  end
end
