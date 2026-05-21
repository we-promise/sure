require "test_helper"

class LoanTest < ActiveSupport::TestCase
  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = build_loan_account(balance: 500000, interest_rate: 3.5, term_months: 360)

    assert_in_delta 2245.22, loan_account.loan.monthly_payment.amount.to_f, 0.01
  end

  test "amortization schedule returns one row per term month" do
    loan_account = build_loan_account(balance: 500000, interest_rate: 3.5, term_months: 360)

    schedule = loan_account.loan.amortization_schedule

    assert_equal 360, schedule.length
    assert_equal 1, schedule.first[:period]
    assert_equal 360, schedule.last[:period]
  end

  test "amortization schedule splits each payment into interest and principal" do
    loan_account = build_loan_account(balance: 240000, interest_rate: 6.0, term_months: 360)

    first = loan_account.loan.amortization_schedule.first

    assert_equal 1200.00, first[:interest].amount.to_f
    assert_in_delta 238.92, first[:principal].amount.to_f, 0.05
    assert_in_delta first[:beginning_balance].amount.to_f - first[:principal].amount.to_f,
                    first[:ending_balance].amount.to_f, 0.01
  end

  test "amortization schedule pays the loan down to zero in the final period" do
    loan_account = build_loan_account(balance: 240000, interest_rate: 6.0, term_months: 360)

    last = loan_account.loan.amortization_schedule.last

    assert_equal 0, last[:ending_balance].amount.to_f
  end

  test "amortization schedule handles zero interest" do
    loan_account = build_loan_account(balance: 12000, interest_rate: 0, term_months: 12)

    schedule = loan_account.loan.amortization_schedule

    assert_equal 12, schedule.length
    assert_equal 0, schedule.first[:interest].amount.to_f
    assert_equal 1000, schedule.first[:principal].amount.to_f
    assert_equal 0, schedule.last[:ending_balance].amount.to_f
  end

  test "amortization schedule is empty for non-fixed loans" do
    loan_account = build_loan_account(balance: 100000, interest_rate: 4.0, term_months: 120, rate_type: "variable")

    assert_empty loan_account.loan.amortization_schedule
    assert_nil loan_account.loan.total_interest
    assert_nil loan_account.loan.payoff_date
  end

  test "amortization schedule is empty when required attributes are missing" do
    loan_account = build_loan_account(balance: 100000, interest_rate: nil, term_months: 120)

    assert_empty loan_account.loan.amortization_schedule
  end

  test "total interest sums interest across the schedule" do
    loan_account = build_loan_account(balance: 240000, interest_rate: 6.0, term_months: 360)

    schedule = loan_account.loan.amortization_schedule
    expected = schedule.sum { |row| row[:interest].amount }

    assert_equal expected, loan_account.loan.total_interest.amount
  end

  test "payoff date equals the date of the final schedule row" do
    loan_account = build_loan_account(balance: 240000, interest_rate: 6.0, term_months: 360)

    assert_equal loan_account.loan.amortization_schedule.last[:payment_date], loan_account.loan.payoff_date
  end

  private
    def build_loan_account(balance:, interest_rate:, term_months:, rate_type: "fixed")
      Account.create! \
        family: families(:dylan_family),
        name: "Loan",
        balance: balance,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage",
          interest_rate: interest_rate,
          term_months: term_months,
          rate_type: rate_type
        )
    end
end
