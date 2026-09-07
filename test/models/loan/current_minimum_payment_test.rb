require "test_helper"

class Loan::CurrentMinimumPaymentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # #15's acceptance criterion, taken from a real lender letter. Both figures
  # reproduce the letter to the cent as stated in the issue; the residual
  # against the LENDER's own printed number is +$0.29 and -$0.75.
  #
  # The +/-$1.00 tolerance is the lender's rounding, not ours: a lender quotes a
  # repayment rounded to its own convention and may size the final payment to
  # absorb the difference. Tightening this to the cent would assert that our
  # rounding matches theirs, which the letter gives no basis for. Loosening it
  # past a dollar would stop the test noticing a wrong term or a wrong rate --
  # one month of term error moves this figure by roughly $6.
  test "the level payment reproduces the lender letter within one dollar" do
    [
      { rate: "6.18", months: 277, lender: "2719.04" },
      { rate: "5.93", months: 279, lender: "2651.07" }
    ].each do |example|
      computed = Loan::AmortizationMath.level_payment(
        balance: BigDecimal("400762.12"),
        monthly_rate: Loan.monthly_rate(example[:rate]),
        remaining_payments: example[:months],
        currency_precision: 2
      )

      assert_in_delta BigDecimal(example[:lender]), computed, BigDecimal("1.00"),
        "#{example[:rate]}% over #{example[:months]} months must match the lender letter"
    end
  end

  test "a variable loan quotes today's balance at today's rate to the original maturity" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 360, months_elapsed: 83)

    assert_equal 277, loan.amortization_schedule.remaining_payment_count
    assert_equal "$2,719.33", loan.current_minimum_payment.format
  end

  # The defect this issue exists to fix: the contracted payment is sized from
  # the ORIGINAL balance at the FIRST payment date, so for a loan years in it
  # describes a loan that no longer exists. The two must not be equal, or the
  # new method is not doing anything.
  test "the current minimum payment differs from the contracted payment for a seasoned loan" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 360, months_elapsed: 83)

    assert_not_equal loan.amortization_schedule.monthly_payment.amount,
      loan.current_minimum_payment.amount,
      "a re-amortised payment that equals the contracted one is not re-amortising"
  end

  test "a fixed-rate loan is unaffected and still quotes the contracted payment" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 360, months_elapsed: 83)
    loan.update!(rate_type: "fixed")

    assert_equal loan.amortization_schedule.monthly_payment, loan.current_minimum_payment
  end

  test "an offset balance reduces the balance the repayment must clear" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 360, months_elapsed: 83)
    offset = @family.accounts.create!(
      name: "Offset", balance: 50_000, currency: loan.account.currency, accountable: Depository.new
    )
    loan.update!(offset_account_ids: [ offset.id ])

    assert_equal Money.new(BigDecimal("350762.12"), loan.account.currency),
      loan.reload.interest_bearing_balance
    assert loan.current_minimum_payment.amount < BigDecimal("2719.33"),
      "an offset balance must lower the repayment, not leave it unchanged"
  end

  # A loan past its maturity has no payments left to spread a balance over, so
  # there is no repayment to quote. Returning a figure here would be inventing
  # a term the loan does not have.
  test "no payments remaining yields no figure rather than a divide by zero" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 12, months_elapsed: 24)

    assert_equal 0, loan.amortization_schedule.remaining_payment_count
    assert_nil loan.current_minimum_payment
  end

  private

    def variable_loan(balance:, rate:, term_months:, months_elapsed:)
      account = @family.accounts.create!(
        name: "Minimum Payment Loan #{SecureRandom.hex(4)}",
        balance: balance,
        currency: "USD",
        accountable: Loan.new(
          rate_type: "variable",
          interest_rate: rate,
          term_months: term_months,
          initial_balance: balance,
          start_date: Date.current - months_elapsed.months
        )
      )
      account.loan
    end
end
