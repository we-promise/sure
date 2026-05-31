require "test_helper"

class LoanTest < ActiveSupport::TestCase
  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal 2245, loan_account.loan.monthly_payment.amount
  end

  test "validates annuity loan settings" do
    loan = Loan.new(annuity_enabled: true, initial_balance: 100000, payment_cadence: "weekly", term_months: 360)

    assert_not loan.valid?
    assert_includes loan.errors[:started_on], "can't be blank"
    assert_includes loan.errors[:payment_cadence], "is not included in the list"
    assert_includes loan.errors[:loan_rate_periods], "must include at least one rate period"
  end

  test "accepts valid annuity loan with a monthly rate period" do
    loan = Loan.new(
      annuity_enabled: true,
      initial_balance: 100000,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      term_months: 360
    )
    loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 5.0)

    assert loan.valid?
  end

  test "annuity original balance uses configured original principal" do
    loan = Loan.new(
      annuity_enabled: true,
      initial_balance: 100000,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      term_months: 360
    )
    loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 5.0)
    account = Account.create!(
      family: families(:dylan_family),
      name: "Partially Paid Mortgage",
      balance: 90000,
      currency: "USD",
      accountable: loan
    )

    assert_equal 100000, account.loan.original_balance.amount
  end

  test "rejects duplicate rate period start dates" do
    loan = Loan.new(
      annuity_enabled: true,
      initial_balance: 100000,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      term_months: 360
    )
    loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 5.0)
    loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)

    assert_not loan.valid?
    assert_includes loan.errors[:loan_rate_periods], "cannot have duplicate start dates"
  end
end
