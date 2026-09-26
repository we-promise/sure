require "test_helper"

class LoanInsuranceTest < ActiveSupport::TestCase
  # 12,000 over 12 months at 0% interest repays 1,000 a month, so every
  # outstanding balance in the schedule is a round number and each premium is
  # hand-computable. 1.2% a year is 0.1% a month.
  def build_loan(insurance_rate:, insurance_rate_type:, balance: 12_000, term: 12, rate: 0)
    account = Account.create!(
      family: families(:dylan_family),
      name: "Insured Loan #{SecureRandom.hex(3)}",
      balance: balance,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: rate,
        term_months: term,
        rate_type: "fixed",
        start_date: Date.new(2026, 1, 1),
        insurance_rate: insurance_rate,
        insurance_rate_type: insurance_rate_type
      )
    )
    account.loan
  end

  # A level-term premium is charged on what was borrowed, for the life of the
  # loan, so it does not fall as the loan is repaid: 12,000 * 0.1% = 12 every
  # month, twelve times.
  test "a level-term premium is charged on the original principal every period" do
    loan = build_loan(insurance_rate: 1.2, insurance_rate_type: "level_term")

    amounts = loan.insurance.premiums.map { |premium| premium.amount.amount }

    assert_equal 12, amounts.size
    assert_equal [ BigDecimal(12) ] * 12, amounts, "a level premium does not decrease"
    assert_equal BigDecimal(144), loan.total_insurance.amount
  end

  # A decreasing premium is charged on what is still outstanding at the START
  # of the period: 12,000 in month one, then 11,000, and so on to 1,000.
  test "a decreasing premium follows the outstanding balance" do
    loan = build_loan(insurance_rate: 1.2, insurance_rate_type: "decreasing_life")

    amounts = loan.insurance.premiums.map { |premium| premium.amount.amount }

    assert_equal (1..12).map { |month| BigDecimal(13 - month) }, amounts
    assert_equal BigDecimal(78), loan.total_insurance.amount, "12 + 11 + ... + 1"
  end

  # A rate with no type recorded is read as decreasing, which never overstates
  # the cost of a policy the borrower has not described.
  test "a premium with no type recorded is read as decreasing" do
    loan = build_loan(insurance_rate: 1.2, insurance_rate_type: nil)

    assert_equal BigDecimal(78), loan.total_insurance.amount
    assert_not loan.insurance.level_term?
  end

  test "no premium is recorded, so there is nothing to charge" do
    loan = build_loan(insurance_rate: nil, insurance_rate_type: nil)

    assert_nil loan.insurance
    assert_equal BigDecimal(0), loan.total_insurance.amount, "money, not nil, so a view can add it"
    assert_equal "USD", loan.total_insurance.currency.iso_code
  end

  # The cost of the loan is what was borrowed, the interest on it, and the
  # premium beside it -- the premium is NOT inside the instalment, so it has to
  # be added rather than read off the schedule's own total.
  test "the total cost adds the premium to principal and interest" do
    loan = build_loan(insurance_rate: 1.2, insurance_rate_type: "level_term",
                      balance: 12_000, term: 12, rate: 6)

    schedule = loan.amortization_schedule

    assert_operator schedule.total_interest.amount, :>, 0, "or this proves nothing about interest"
    assert_equal loan.original_balance + schedule.total_interest + loan.total_insurance,
                 loan.total_cost
    assert_equal BigDecimal(144), loan.total_insurance.amount,
                 "a level premium does not care what the interest rate is"
  end

  test "a loan with nothing to amortise has no cost to report" do
    loan = build_loan(insurance_rate: 1.2, insurance_rate_type: "level_term", term: 0)

    assert_nil loan.amortization_schedule
    assert_nil loan.insurance
    assert_nil loan.total_cost, "nil rather than a cost with no interest in it"
  end

  # The memo has to drop when either the premium's own inputs or the schedule's
  # change, or a loan re-read after an edit answers with the old policy.
  test "changing a rate drops the memoised premium" do
    loan = build_loan(insurance_rate: 1.2, insurance_rate_type: "level_term")

    assert_equal BigDecimal(144), loan.total_insurance.amount

    loan.insurance_rate = 2.4
    assert_equal BigDecimal(288), loan.total_insurance.amount, "the premium's own input"

    loan.insurance_rate_type = "decreasing_life"
    assert_equal BigDecimal(156), loan.total_insurance.amount, "and its type"

    loan.term_months = 6
    assert_equal 6, loan.insurance.premiums.size, "and the schedule it is charged against"
  end
end
