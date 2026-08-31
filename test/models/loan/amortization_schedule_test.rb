require "test_helper"

class Loan::AmortizationScheduleTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @loan_account = Account.create! \
      family: @family,
      name: "Test Mortgage",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )
    @loan = @loan_account.loan
    @schedule = @loan.amortization_schedule
  end

  test "schedule is amortizable for fixed rate loan with positive principal and term" do
    assert @schedule.amortizable?
  end

  test "schedule is not amortizable for variable rate loan" do
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: 3.5,
        term_months: 360
      )

    schedule = variable_loan.loan.amortization_schedule
    assert_not schedule.amortizable?
  end

  test "schedule is not amortizable for zero principal" do
    zero_loan = Account.create! \
      family: @family,
      name: "Zero Loan",
      balance: 0,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "fixed",
        interest_rate: 3.5,
        term_months: 360
      )

    schedule = zero_loan.loan.amortization_schedule
    assert_not schedule.amortizable?
  end

  test "schedule is not amortizable for zero term" do
    zero_term_loan = Account.create! \
      family: @family,
      name: "Zero Term Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "fixed",
        interest_rate: 3.5,
        term_months: 0
      )

    schedule = zero_term_loan.loan.amortization_schedule
    assert_not schedule.amortizable?
  end

  test "monthly payment is calculated correctly" do
    payment = @schedule.monthly_payment
    assert_equal BigDecimal("2245.22"), payment.amount
  end

  test "zero interest rate calculates straight line principal" do
    zero_interest_loan = Account.create! \
      family: @family,
      name: "Zero Interest Loan",
      balance: 120000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "fixed",
        interest_rate: 0,
        term_months: 120
      )

    schedule = zero_interest_loan.loan.amortization_schedule
    payment = schedule.monthly_payment
    assert_equal BigDecimal("1000"), payment.amount
  end

  test "payment schedule has correct number of payments" do
    assert_equal 360, @schedule.payment_count
  end

  test "first payment is principal + interest" do
    first_payment = @schedule.payments.first
    assert_equal 1, first_payment[:payment_number]
    assert_equal BigDecimal("500000"), first_payment[:beginning_balance]
    assert first_payment[:interest_payment] > 0
    assert first_payment[:principal_payment] > 0
  end

  test "final payment clears balance" do
    last_payment = @schedule.payments.last
    assert_equal 0, last_payment[:ending_balance]
  end

  test "principal portions sum to original principal" do
    total_principal = @schedule.payments.sum { |p| p[:principal_payment] }
    assert_equal BigDecimal("500000"), total_principal.round(2)
  end

  test "ending balance decreases monotonically" do
    balances = @schedule.payments.map { |p| p[:ending_balance] }
    balances.each_cons(2) do |prev, curr|
      assert curr <= prev, "Ending balance should decrease monotonically"
    end
  end

  test "beginning_balance of next payment equals ending_balance of current" do
    @schedule.payments.each_cons(2) do |current, next_payment|
      assert_equal current[:ending_balance], next_payment[:beginning_balance]
    end
  end

  test "payment_for returns correct payment data" do
    payment_date = @schedule.payments.first[:payment_date]
    payment = @schedule.payment_for(payment_date)

    assert payment.present?
    assert_equal 1, payment[:payment_number]
    assert_equal payment_date, payment[:payment_date]
  end

  test "payment_for returns nil for non-existent date" do
    payment = @schedule.payment_for(Date.new(2100, 1, 1))
    assert_nil payment
  end

  test "total_cost equals principal plus total_interest" do
    expected_total_cost = @loan.original_balance + @schedule.total_interest
    assert_equal expected_total_cost, @schedule.total_cost
  end

  test "payoff_date is set correctly" do
    payoff_date = @schedule.payoff_date
    assert payoff_date.present?
    assert payoff_date > Date.current
  end

  test "schedule handles small loan amounts" do
    small_loan = Account.create! \
      family: @family,
      name: "Small Loan",
      balance: 1000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "fixed",
        interest_rate: 5.0,
        term_months: 12
      )

    schedule = small_loan.loan.amortization_schedule
    assert schedule.amortizable?
    assert_equal 12, schedule.payment_count
    assert_equal 0, schedule.payments.last[:ending_balance]
  end

  test "schedule with different currency precision" do
    jpy_loan = Account.create! \
      family: @family,
      name: "JPY Loan",
      balance: 5000000,
      currency: "JPY",
      accountable: Loan.create!(
        rate_type: "fixed",
        interest_rate: 3.5,
        term_months: 360
      )

    schedule = jpy_loan.loan.amortization_schedule
    assert schedule.amortizable?
    assert_equal 360, schedule.payment_count
  end

  test "monthly payment calculation with very low interest rate" do
    low_rate_loan = Account.create! \
      family: @family,
      name: "Low Rate Loan",
      balance: 100000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "fixed",
        interest_rate: 0.5,
        term_months: 120
      )

    schedule = low_rate_loan.loan.amortization_schedule
    payment = schedule.monthly_payment
    assert payment.positive?
    assert payment < Money.new(1000, "USD")
  end
end
