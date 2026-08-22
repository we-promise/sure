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

    assert_equal BigDecimal("2245.22"), loan_account.loan.monthly_payment.amount
  end

  test "monthly payment is zero for a non-positive term" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Backwards Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: -360,
        rate_type: "fixed"
      )

    assert_equal 0, loan_account.loan.monthly_payment.amount
    assert_not loan_account.loan.amortizable?
  end

  test "variable rate loans have no payment or schedule" do
    loan = Loan.new(interest_rate: 3.5, term_months: 360, rate_type: "variable")

    assert_not loan.amortizable?
  end
end
