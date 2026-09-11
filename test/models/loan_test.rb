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

  # Reversed in part by #104: a variable loan now has a schedule. It still has
  # no single monthly payment, because it does not have one -- quoting the
  # payment it opened with would present a stale figure as a current one.
  test "variable rate loans have a schedule but no single monthly payment" do
    account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "variable")

    assert account.loan.amortizable?
    assert_not_nil account.loan.amortization_schedule
    assert_nil account.loan.monthly_payment
  end

  # #100 decision 8: a provider writes its own vocabulary straight into
  # rate_type (Plaid's mortgage payload says "arm", others capitalise), and a
  # loan whose rate can move is variable whatever the word for it. Only a
  # blank rate type says nothing at all.
  test "any non-blank rate type other than fixed is a variable, amortizable loan" do
    [ "arm", "Variable" ].each do |provider_rate_type|
      account = Account.create! \
        family: families(:dylan_family),
        name: "Provider Mortgage",
        balance: 500000,
        currency: "USD",
        accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: provider_rate_type)

      assert account.loan.variable_rate_type?, "#{provider_rate_type.inspect} should read as variable"
      assert account.loan.amortizable?, "#{provider_rate_type.inspect} should amortize"
      assert_nil account.loan.monthly_payment, "a variable loan has no single monthly payment"
    end

    [ nil, "" ].each do |blank|
      account = Account.create! \
        family: families(:dylan_family),
        name: "Untyped Mortgage",
        balance: 500000,
        currency: "USD",
        accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: blank)

      assert_not account.loan.variable_rate_type?, "#{blank.inspect} says nothing about the rate"
      assert_not account.loan.amortizable?, "#{blank.inspect} must not amortize"
    end
  end

  test "a loan with no account is not amortizable rather than raising" do
    assert_not Loan.new(interest_rate: 3.5, term_months: 360, rate_type: "variable").amortizable?
    assert_not Loan.new(interest_rate: 3.5, term_months: 360, rate_type: "fixed").amortizable?
  end

  test "a start date in the future is rejected, today and blank are not" do
    loan = Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 12, rate_type: "fixed")

    loan.start_date = Date.current + 1
    assert_not loan.valid?
    assert loan.errors.of_kind?(:start_date, :less_than_or_equal_to)

    loan.start_date = Date.current
    assert loan.valid?

    loan.start_date = nil
    assert loan.valid?
  end
end
