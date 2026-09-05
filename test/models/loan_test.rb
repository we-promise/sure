require "test_helper"

class LoanTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @loan = @account.loan
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

    assert_equal 2245, loan_account.loan.monthly_payment.amount
  end

  # ---- fixed rate: the payment is computed --------------------------------

  test "a fixed-rate loan computes its own instalment" do
    @loan.update!(rate_type: "fixed", interest_rate: 3.5, term_months: 360)

    assert_not_nil @loan.effective_payment
    assert_equal @loan.monthly_payment, @loan.effective_payment
  end

  test "an explicit scheduled payment overrides the computed one" do
    @loan.update!(rate_type: "fixed", interest_rate: 3.5, term_months: 360, scheduled_payment: 1234)

    assert_equal 1234, @loan.effective_payment.amount
  end

  # ---- variable rate: the payment must be supplied -------------------------

  test "a variable-rate loan has no computable instalment" do
    @loan.update!(rate_type: "variable", interest_rate: 3.5, term_months: 360, scheduled_payment: nil)

    assert_nil @loan.monthly_payment
    assert_nil @loan.effective_payment
    assert_nil @loan.remaining_payments
    assert_nil @loan.remaining_interest
  end

  test "a variable-rate loan amortizes once the real payment is recorded" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "variable", interest_rate: 6, term_months: nil, scheduled_payment: 500)

    assert_equal 500, @loan.effective_payment.amount
    assert @loan.remaining_payments.between?(20, 24),
           "10k at 6% paid 500/month clears in roughly 21 months, got #{@loan.remaining_payments}"
    assert_not_nil @loan.payoff_date
  end

  # ---- amortization edge cases --------------------------------------------

  test "a payment that does not cover the monthly interest reports no schedule" do
    @account.update!(balance: 100_000)
    @loan.update!(rate_type: "variable", interest_rate: 12, scheduled_payment: 100)

    assert_nil @loan.remaining_payments,
               "1000 of monthly interest against a 100 payment never amortizes"
    assert_nil @loan.remaining_interest
  end

  test "a zero-interest loan divides the balance by the payment" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100)

    assert_equal 12, @loan.remaining_payments
  end

  # A declared 0% is a rate. A blank one is not, and treating it as zero quoted
  # the payoff count of an interest-free loan: always too short, and delivered
  # to the assistant through get_liabilities as if it were established.
  test "an unknown interest rate yields no payoff count rather than a zero-rate one" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: nil, scheduled_payment: 100)

    assert_nil @loan.remaining_payments
    assert_nil @loan.payoff_date
    assert_nil @loan.remaining_interest
  end

  test "a cleared loan has no payments left" do
    @account.update!(balance: 0)
    @loan.update!(rate_type: "fixed", interest_rate: 3.5, term_months: 360)

    assert_equal 0, @loan.remaining_payments
  end

  test "remaining payments follow the live balance, not the original term" do
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100, term_months: 360)

    @account.update!(balance: 1_000)
    before = @loan.remaining_payments

    @account.update!(balance: 500)
    @loan.reload

    assert_operator @loan.remaining_payments, :<, before
  end

  # ---- insurance and total cost -------------------------------------------

  test "the total monthly cost adds the insurance premium to the instalment" do
    @loan.update!(rate_type: "variable", scheduled_payment: 400, insurance_monthly_amount: 25)

    assert_equal 400, @loan.effective_payment.amount
    assert_equal 425, @loan.total_monthly_cost.amount
  end

  test "the total monthly cost equals the instalment when there is no insurance" do
    @loan.update!(rate_type: "variable", scheduled_payment: 400, insurance_monthly_amount: nil)

    assert_equal 400, @loan.total_monthly_cost.amount
  end

  test "remaining interest excludes insurance" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100, insurance_monthly_amount: 50)

    assert_equal 0, @loan.remaining_interest.amount, "a zero-rate loan owes no interest"
  end

  # 1,201 at 0% in instalments of 12 needs 101 payments, and the last one is a
  # single unit, not a twelfth full payment. Counting it full quoted 11 of
  # interest on an interest-free loan.
  test "the final instalment of a non-divisible zero-rate balance is not a full payment" do
    @account.update!(balance: 1_201)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 12)

    assert_equal 101, @loan.remaining_payments
    assert_equal 0, @loan.remaining_interest.amount, "a zero-rate loan owes no interest at any balance"
  end

  test "an interest-bearing loan still reports the interest it really owes" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "variable", interest_rate: 6, scheduled_payment: 500)

    interest = @loan.remaining_interest.amount

    assert_operator interest, :>, 0
    # 10k at 6% cleared in ~21 monthly payments of 500 costs a few hundred in
    # interest; the old full-final-payment total overstated it by up to 500.
    assert_operator interest, :<, 600
  end

  # ---- payoff date ---------------------------------------------------------

  test "a recorded maturity date wins over the projected one" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100,
                  maturity_date: Date.new(2030, 6, 30))

    assert_equal Date.new(2030, 6, 30), @loan.payoff_date
  end

  test "the payoff date is projected when no maturity date was recorded" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100, maturity_date: nil)

    assert_equal Date.current.advance(months: 12), @loan.payoff_date
  end

  # ---- APR is not the amortization rate ------------------------------------

  test "apr is stored separately and never drives the schedule" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: 0, apr: 9.9, scheduled_payment: 100)

    assert_equal 9.9, @loan.apr.to_f
    assert_equal 12, @loan.remaining_payments, "the nominal rate drives the schedule, not the TAEG"
  end

  test "contract_terms? reports whether any contract detail was recorded" do
    @loan.update!(origination_date: nil, maturity_date: nil, apr: nil,
                  insurance_monthly_amount: nil, scheduled_payment: nil, early_repayment_terms: nil)
    assert_not @loan.contract_terms?

    @loan.update!(apr: 5.9)
    assert @loan.contract_terms?
  end
end
