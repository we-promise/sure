require "test_helper"

class LoanTest < ActiveSupport::TestCase
  # Leverage is what the down payment is FOR: 80,000 borrowed against 20,000 put
  # in is 4x, and the same loan against 5,000 is 16x. Bands are read off the
  # ratio rather than stored, so a loan re-read after an edit cannot disagree
  # with its own figure.
  test "leverage is the borrowed amount over the down payment" do
    loan = build_loan_account(balance: 80_000, down_payment: 20_000).loan

    assert_in_delta 4.0, loan.initial_leverage_ratio, 0.001
    assert_equal :conservative, loan.leverage_band, "4x sits on the conservative boundary"

    loan.down_payment = 5_000
    assert_in_delta 16.0, loan.initial_leverage_ratio, 0.001
    assert_equal :high, loan.leverage_band
  end

  test "a moderate loan lands in the middle band" do
    loan = build_loan_account(balance: 80_000, down_payment: 16_000).loan

    assert_in_delta 5.0, loan.initial_leverage_ratio, 0.001
    assert_equal :moderate, loan.leverage_band
  end

  # No deposit recorded is not a deposit of zero: a loan nobody has told us
  # about is not infinitely leveraged, and a view must be able to tell the two
  # apart to decide whether to show the figure at all.
  test "a loan with no down payment recorded has no leverage figure" do
    loan = build_loan_account(balance: 80_000, down_payment: nil).loan

    assert_nil loan.initial_leverage_ratio
    assert_nil loan.leverage_band

    loan.down_payment = 0
    assert_nil loan.initial_leverage_ratio, "zero is not a deposit either"
  end

  # Imports can open a loan at a negative valuation. That is no amount borrowed
  # to measure a deposit against, and a ratio from it has no band to name.
  test "a negative opening balance has no leverage figure" do
    loan = loans(:one)
    loan.down_payment = 100_000
    loan.stubs(:original_balance).returns(Money.new(-500_000, "USD"))

    assert_nil loan.initial_leverage_ratio
    assert_nil loan.leverage_band
  end

  test "rejects a negative down payment or insurance rate" do
    loan = Loan.new(down_payment: -1, insurance_rate: -1, insurance_rate_type: "nonsense")

    assert_not loan.valid?
    assert_includes loan.errors[:down_payment], "must be greater than or equal to 0"
    assert_includes loan.errors[:insurance_rate], "must be greater than or equal to 0"
    assert_includes loan.errors[:insurance_rate_type], "is not included in the list"
  end

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

    assert_equal account, account.loan.account, "validating a Loan before attaching its Account must not cache a missing association"
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

  # An imported loan is the case where what was borrowed and what has been seen
  # are different numbers. Plaid sends `origination_principal_amount`, which
  # lands in `initial_balance`; the first valuation the account carries is
  # whatever the balance was on the day it was linked, years of repayments in.
  #
  # 20,000 borrowed, 10,000 outstanding, 5,000 deposit, a level-term policy at
  # 0.36% a year. Every figure below was measured against the 10,000 before
  # this: the schedule amortised half a loan, the borrower had repaid "none" of
  # it, the deposit looked twice as effective as it was, and the premium was
  # half what the policy charges.
  # Four separate tests rather than four assertions, so each figure is observed
  # to fail on its own: one of them failing first would otherwise hide the rest.
  test "the principal is the recorded one, not the first tracked balance" do
    loan = build_imported_loan_account.loan

    assert_equal 20_000, loan.original_balance.amount
  end

  test "the schedule amortises what was borrowed" do
    loan = build_imported_loan_account.loan

    repaid = loan.amortization_schedule.payments.sum(BigDecimal("0")) { |payment| payment.principal.amount }

    assert_in_delta 20_000, repaid, 1, "half a loan was being amortised"
  end

  test "repaid is measured against what was borrowed" do
    loan = build_imported_loan_account.loan

    assert_in_delta 0.5, loan.balance_paid_ratio, 0.0001, "10,000 outstanding on 20,000 borrowed is half repaid"
  end

  test "leverage is measured against what was borrowed" do
    loan = build_imported_loan_account.loan

    assert_in_delta 4.0, loan.initial_leverage_ratio, 0.001, "20,000 against a 5,000 deposit"
  end

  test "a level-term premium is charged on what was borrowed" do
    loan = build_imported_loan_account.loan

    assert_equal 6, Loan::Insurance.for(loan).premium_for(1).amount.amount, "0.36% a year on 20,000"
  end

  # The fallback, which is every loan created here: no principal is recorded
  # separately from the opening valuation, and the two must not disagree.
  test "a loan with no recorded principal still reads its first valuation" do
    loan = build_loan_account(balance: 80_000, down_payment: 20_000).loan

    assert_nil loan.initial_balance
    assert_equal 80_000, loan.original_balance.amount
  end

  # An import can write either, and neither is an amount borrowed, so both fall
  # back rather than producing a zero or a negative principal.
  test "a zero or negative recorded principal falls back to the first valuation" do
    account = build_loan_account(balance: 80_000, down_payment: 20_000)

    account.loan.update!(initial_balance: 0)
    assert_equal 80_000, account.loan.reload.original_balance.amount

    account.loan.update!(initial_balance: -5_000)
    assert_equal 80_000, account.loan.reload.original_balance.amount
  end

  private
    # A loan imported part way through its life: the principal it was written
    # for is recorded, and the only valuation the account carries is the
    # balance on the day it was linked.
    def build_imported_loan_account
      account = Account.create!(
        family: families(:dylan_family),
        name: "Imported #{SecureRandom.hex(3)}",
        balance: 10_000,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage", interest_rate: 5, term_months: 120, rate_type: "fixed",
          initial_balance: 20_000, down_payment: 5_000,
          insurance_rate: 0.36, insurance_rate_type: "level_term",
          start_date: 5.years.ago.to_date
        )
      )
      account.entries.create!(
        name: "Starting balance", amount: 10_000, currency: "USD",
        date: 5.years.ago.to_date, entryable: Valuation.new(kind: "opening_anchor")
      )
      account
    end

    def build_loan_account(balance:, down_payment:)
      Account.create!(
        family: families(:dylan_family),
        name: "Leveraged #{SecureRandom.hex(3)}",
        balance: balance,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage", interest_rate: 5, term_months: 120,
          rate_type: "fixed", down_payment: down_payment
        )
      )
    end
end
