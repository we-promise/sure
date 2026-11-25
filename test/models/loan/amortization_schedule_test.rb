require "test_helper"

class Loan::AmortizationScheduleTest < ActiveSupport::TestCase
  test "builds one payment per month of the term" do
    schedule = build_schedule

    assert_equal 360, schedule.payments.count
    assert_equal 1, schedule.payments.first.number
    assert_equal 360, schedule.payments.last.number
  end

  test "level payment matches the standard amortization formula" do
    assert_equal BigDecimal("2245.22"), build_schedule.periodic_payment.amount
  end

  test "first payment is mostly interest and last payment is mostly principal" do
    schedule = build_schedule
    first = schedule.payments.first
    last = schedule.payments.last

    # 500,000 at 3.5% => 1,458.33 of interest in month one.
    assert_equal BigDecimal("1458.33"), first.interest.amount
    assert_equal BigDecimal("786.89"), first.principal.amount
    assert first.interest.amount > first.principal.amount
    assert last.principal.amount > last.interest.amount
  end

  test "amortizes down to exactly zero" do
    assert_equal BigDecimal("0"), build_schedule.payments.last.ending_balance.amount
  end

  test "principal portions sum to the original principal" do
    schedule = build_schedule
    total_principal = schedule.payments.sum(BigDecimal(0)) { |payment| payment.principal.amount }

    assert_equal BigDecimal("500000"), total_principal
  end

  test "total paid is principal plus total interest" do
    schedule = build_schedule

    # Slightly above the naive payment*term figure because interest is rounded
    # to cents every month, exactly as a lender's table does.
    assert_equal BigDecimal("308281.36"), schedule.total_interest.amount
    assert_equal schedule.principal + schedule.total_interest.amount, schedule.total_paid.amount
  end

  test "payment dates step monthly from origination" do
    schedule = build_schedule(start_date: Date.new(2026, 1, 31))

    assert_equal Date.new(2026, 2, 28), schedule.payments.first.date
    assert_equal Date.new(2026, 3, 31), schedule.payments.second.date
  end

  test "payoff date is the last payment date" do
    schedule = build_schedule(start_date: Date.new(2026, 1, 1), term_months: 12)

    assert_equal Date.new(2027, 1, 1), schedule.payoff_date
  end

  test "handles a zero-interest loan with straight-line principal" do
    schedule = build_schedule(annual_rate: 0, term_months: 10, principal: 1000)

    assert_equal BigDecimal("100"), schedule.periodic_payment.amount
    assert schedule.payments.all? { |payment| payment.interest.amount.zero? }
    assert_equal BigDecimal("0"), schedule.total_interest.amount
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "rounds to whole units for a currency without minor units" do
    schedule = build_schedule(currency: "JPY", principal: 1_000_000, annual_rate: 2, term_months: 12)

    assert schedule.payments.all? { |payment| payment.payment.amount.frac.zero? }
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "returns no payments when the term is zero" do
    assert_empty build_schedule(term_months: 0).payments
    assert_nil build_schedule(term_months: 0).payoff_date
    assert_equal BigDecimal("0"), build_schedule(term_months: 0).periodic_payment.amount
    assert_equal BigDecimal("0"), build_schedule(principal: 0).periodic_payment.amount
  end

  test "keeps the periods it built when rounding clears the balance early" do
    # 10 over 51 months rounds to a 0.20 payment, which pays the loan off in 50.
    schedule = build_schedule(principal: 10, annual_rate: 0, term_months: 51)

    assert_equal 50, schedule.payments.count
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
    assert_equal BigDecimal("10"), schedule.total_paid.amount
    assert_equal schedule.payments.last.date, schedule.payoff_date
  end

  test "payment_for finds the payment landing in a given month" do
    schedule = build_schedule(start_date: Date.new(2026, 1, 1), term_months: 12)

    assert_equal 3, schedule.payment_for(Date.new(2026, 4, 17)).number
    assert_nil schedule.payment_for(Date.new(2030, 1, 1))
  end

  test "builds from a loan record" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "fixed").loan

    assert_equal BigDecimal("2245.22"), Loan::AmortizationSchedule.for(loan).periodic_payment.amount
  end

  # Reversed by #104. A variable loan was excluded while a schedule could only
  # be built off one rate; it now re-amortises at each recorded change, so the
  # reason for the exclusion is gone.
  test "is buildable for a variable rate loan" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "variable").loan

    assert_not_nil Loan::AmortizationSchedule.for(loan)
  end

  # A rate type outside the form's vocabulary is still a rate type (#100
  # decision 8). PlaidAccount::Liabilities::MortgageProcessor writes Plaid's
  # raw `interest_rate.type` straight through, so this is reachable from a
  # sync, not only from the form, and such a loan is variable rather than
  # unknown.
  test "is buildable for a provider's own rate type" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "teaser").loan

    assert_not_nil Loan::AmortizationSchedule.for(loan)
  end

  # What is still not buildable: no rate type at all.
  test "is not buildable for a blank rate type" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "").loan

    assert_nil Loan::AmortizationSchedule.for(loan)
  end

  # A lender's own figures, when they differ from the computed ones:
  # `contracted_payment` holds the instalment, `balloon_payment` replaces the
  # last instalment's total. The schedules below reproduce a real table --
  # 3,800,000 at 11.25% over 36 months, where the lender charges 69,282
  # rather than the 69,281.66 the formula would size.
  test "a contracted payment is held for the whole term and the last row settles" do
    schedule = build_schedule(
      principal: 3_800_000, annual_rate: 11.25, term_months: 36,
      start_date: Date.new(2023, 1, 16), contracted_payment: 69_282
    )

    assert_equal 36, schedule.payments.count
    assert_equal BigDecimal("69282"), schedule.periodic_payment.amount
    assert schedule.payments.first(35).all? { |payment| payment.payment.amount == BigDecimal("69282") }

    first = schedule.payments.first
    assert_equal BigDecimal("33657.00"), first.principal.amount
    assert_equal BigDecimal("35625.00"), first.interest.amount

    assert_equal BigDecimal("2413360.48"), schedule.payments[34].ending_balance.amount

    last = schedule.payments.last
    assert_equal BigDecimal("2435985.73"), last.payment.amount
    assert_equal BigDecimal("2413360.48"), last.principal.amount
    assert_equal BigDecimal("22625.25"), last.interest.amount
    assert_equal BigDecimal("0"), last.ending_balance.amount

    assert_equal BigDecimal("1060855.73"), schedule.total_interest.amount
  end

  test "a balloon replaces the final instalment's total and interest absorbs the difference" do
    schedule = build_schedule(
      principal: 3_800_000, annual_rate: 11.25, term_months: 36,
      start_date: Date.new(2023, 1, 16), contracted_payment: 69_282, balloon_payment: 2_436_000
    )

    last = schedule.payments.last
    assert_equal BigDecimal("2436000"), last.payment.amount
    assert_equal BigDecimal("2413360.48"), last.principal.amount
    # A plug, not the accrued 22625.25: the lender quotes the round total and
    # interest takes what is left.
    assert_equal BigDecimal("22639.52"), last.interest.amount
    assert_equal BigDecimal("0"), last.ending_balance.amount

    assert_equal BigDecimal("1060870.00"), schedule.total_interest.amount
  end

  test "a balloon alone sizes the instalments so the last one equals it" do
    schedule = build_schedule(
      principal: 3_800_000, annual_rate: 11.25, term_months: 36,
      start_date: Date.new(2023, 1, 16), balloon_payment: 2_436_000
    )

    assert_equal 36, schedule.payments.count
    assert schedule.payments.first(35).all? { |payment| payment.payment.amount == BigDecimal("69281.66") }
    assert_equal BigDecimal("2413374.46"), schedule.payments[34].ending_balance.amount

    last = schedule.payments.last
    assert_equal BigDecimal("2436000"), last.payment.amount
    assert_equal BigDecimal("2413374.46"), last.principal.amount
    assert_equal BigDecimal("22625.54"), last.interest.amount
    assert_equal BigDecimal("0"), last.ending_balance.amount
  end

  test "a contracted payment on another loan still settles exactly at the term" do
    schedule = build_schedule(
      principal: 995_970, annual_rate: 9, term_months: 60, contracted_payment: 20_675
    )

    assert_equal 60, schedule.payments.count
    assert_equal BigDecimal("20498.58"), schedule.payments[58].ending_balance.amount

    last = schedule.payments.last
    assert_equal BigDecimal("20652.32"), last.payment.amount
    assert_equal BigDecimal("153.74"), last.interest.amount
    assert_equal BigDecimal("0"), last.ending_balance.amount

    assert_equal BigDecimal("244507.32"), schedule.total_interest.amount
  end

  test "a balloon that does not cover the balance leaves the rest outstanding" do
    schedule = build_schedule(
      principal: 3_800_000, annual_rate: 11.25, term_months: 36,
      start_date: Date.new(2023, 1, 16), contracted_payment: 69_282, balloon_payment: 2_000_000
    )

    last = schedule.payments.last
    assert_equal BigDecimal("2000000"), last.payment.amount
    assert_equal BigDecimal("2000000"), last.principal.amount
    assert_equal BigDecimal("0"), last.interest.amount
    assert_equal BigDecimal("413360.48"), last.ending_balance.amount
  end

  # With nothing recorded the run is the one it always was: the fixture loan
  # carries neither column and gets the payment the formula sizes.
  test "a loan without contracted figures builds the schedule it always did" do
    loan = loans(:one)
    assert_nil loan.contracted_payment
    assert_nil loan.balloon_payment

    assert_equal BigDecimal("2245.22"), Loan::AmortizationSchedule.for(loan).periodic_payment.amount
  end

  # The figures reach the simulator through `for`: the column on the loan,
  # not a number handed in by the caller.
  test "builds from a loan record's contracted payment" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "fixed",
                        contracted_payment: 2_300).loan

    assert_equal BigDecimal("2300"), Loan::AmortizationSchedule.for(loan).periodic_payment.amount
  end

  test "balloon_level_payment spreads what the balloon does not cover at a zero rate" do
    assert_equal BigDecimal("5000.00"), Loan::AmortizationMath.balloon_level_payment(
      balance: 120_000, monthly_rate: 0, payments: 13, balloon: 60_000, currency_precision: 2
    )
  end

  private
    def build_schedule(principal: 500_000, annual_rate: 3.5, term_months: 360,
                       start_date: Date.new(2026, 1, 1), currency: "USD",
                       contracted_payment: nil, balloon_payment: nil)
      Loan::AmortizationSchedule.new(
        principal: principal,
        annual_rate: annual_rate,
        term_months: term_months,
        start_date: start_date,
        currency: currency,
        contracted_payment: contracted_payment,
        balloon_payment: balloon_payment
      )
    end

    def loan_account(**loan_attrs)
      Account.create! \
        family: families(:dylan_family),
        name: "Mortgage Loan",
        balance: 500_000,
        currency: "USD",
        accountable: Loan.create!(subtype: "mortgage", **loan_attrs)
    end
end
