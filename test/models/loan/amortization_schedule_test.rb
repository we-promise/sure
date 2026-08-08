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

  test "is not buildable for a variable rate loan" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "variable").loan

    assert_nil Loan::AmortizationSchedule.for(loan)
  end

  private
    def build_schedule(principal: 500_000, annual_rate: 3.5, term_months: 360,
                       start_date: Date.new(2026, 1, 1), currency: "USD")
      Loan::AmortizationSchedule.new(
        principal: principal,
        annual_rate: annual_rate,
        term_months: term_months,
        start_date: start_date,
        currency: currency
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
