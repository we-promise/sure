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

  test "splits_payments? requires the toggle and a positive rate" do
    loan = Loan.new(auto_split_payments: true, interest_rate: 6)
    assert loan.splits_payments?

    assert_not Loan.new(auto_split_payments: false, interest_rate: 6).splits_payments?
    assert_not Loan.new(auto_split_payments: true, interest_rate: nil).splits_payments?
    assert_not Loan.new(auto_split_payments: true, interest_rate: 0).splits_payments?
  end

  test "computes interest and principal portions from outstanding balance and rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Auto Loan",
      balance: 10000,
      currency: "USD",
      accountable: Loan.create!(subtype: "auto", interest_rate: 6, rate_type: "fixed", auto_split_payments: true)

    loan = loan_account.loan

    # No materialized balances yet -> falls back to original balance (10000).
    # Monthly interest = 10000 * 6% / 12 = 50; principal = payment - interest.
    assert_equal 50, loan.interest_portion(payment_amount: 300, as_of_date: Date.current).amount
    assert_equal 250, loan.principal_portion(payment_amount: 300, as_of_date: Date.current).amount
  end

  test "interest portion is clamped to the payment amount for tiny payments" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Auto Loan",
      balance: 10000,
      currency: "USD",
      accountable: Loan.create!(subtype: "auto", interest_rate: 6, rate_type: "fixed", auto_split_payments: true)

    loan = loan_account.loan

    # Accrued interest would be 50, but the payment is only 30.
    assert_equal 30, loan.interest_portion(payment_amount: 30, as_of_date: Date.current).amount
    assert_equal 0, loan.principal_portion(payment_amount: 30, as_of_date: Date.current).amount
  end
end
