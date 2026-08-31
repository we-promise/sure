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

  test "amortization_schedule returns valid schedule for fixed rate loan" do
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

    schedule = loan_account.loan.amortization_schedule
    assert schedule.amortizable?
    assert_equal 360, schedule.payment_count
    assert schedule.payoff_date.present?
    assert schedule.total_interest.positive?
    assert schedule.monthly_payment.positive?
  end

  test "amortization_schedule is amortizable for variable rate loan with a base rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    schedule = loan_account.loan.amortization_schedule
    assert schedule.amortizable?
  end

  test "amortization_schedule not amortizable for loan without an interest rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "No Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "other",
        interest_rate: nil,
        term_months: 360,
        rate_type: "fixed"
      )

    schedule = loan_account.loan.amortization_schedule
    assert_not schedule.amortizable?
  end

  test "amortizable? is false before the loan has an account" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 360,
      rate_type: "fixed"
    )

    assert_nil loan.account
    assert_not loan.amortizable?
    assert_equal 0, loan.amortizations.count
  end

  test "rebuild_amortization_schedule is triggered automatically when terms change" do
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

    loan = loan_account.loan
    assert_equal 0, loan.amortizations.count

    loan.update!(interest_rate: 4.0)
    assert_equal 360, loan.amortizations.count
  end

  test "adds variable rate changes" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    loan = loan_account.loan
    loan.add_variable_rate_change(Date.new(2027, 1, 1), 4.0)
    loan.add_variable_rate_change(Date.new(2028, 1, 1), 4.5)

    assert_equal 2, loan.variable_rates.length
    assert_equal 4.0, loan.variable_rates[0][1]
    assert_equal 4.5, loan.variable_rates[1][1]
  end

  test "gets current variable rate based on date" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable",
        variable_rate_schedule: {
          "2024-01-01" => 3.5,
          "2026-01-01" => 4.0,
          "2027-01-01" => 4.5
        }
      )

    loan = loan_account.loan
    assert_equal 3.5, loan.current_variable_rate(Date.new(2024, 6, 1))
    assert_equal 4.0, loan.current_variable_rate(Date.new(2026, 6, 1))
    assert_equal 4.5, loan.current_variable_rate(Date.new(2027, 6, 1))
  end
end
