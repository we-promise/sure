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

  test "schedule is amortizable for variable rate loan with a base interest rate" do
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
    assert schedule.amortizable?
    assert_equal 360, schedule.payment_count
  end

  test "schedule is not amortizable for variable rate loan without an interest rate" do
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan No Rate",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: nil,
        term_months: 360
      )

    schedule = variable_loan.loan.amortization_schedule
    assert_not schedule.amortizable?
  end

  test "variable rate loan applies configured rate changes on their effective dates" do
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan With Changes",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: 3.5,
        term_months: 360,
        start_date: 2.years.ago.to_date
      )
    loan = variable_loan.loan
    loan.add_variable_rate_change(loan.start_date, 3.5)
    loan.add_variable_rate_change(loan.start_date + 12.months, 4.5)

    schedule = loan.amortization_schedule
    payments = schedule.payments

    before_change = payments.find { |p| p[:payment_date] < loan.start_date + 12.months }
    after_change = payments.find { |p| p[:payment_date] >= loan.start_date + 12.months }

    assert_equal 3.5, before_change[:interest_rate].to_f
    assert_equal 4.5, after_change[:interest_rate].to_f
  end

  test "variable rate changes between payments use the latest rate on the next payment" do
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan Multiple Changes",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: 3.5,
        term_months: 6,
        start_date: Date.new(2023, 1, 1)
      )
    loan = variable_loan.loan
    loan.add_variable_rate_change(Date.new(2023, 2, 15), 4.5)
    loan.add_variable_rate_change(Date.new(2023, 2, 20), 5.5)

    payments = loan.amortization_schedule.payments

    assert_equal 6, payments.length
    assert_equal Date.new(2023, 2, 1), payments[0][:payment_date]
    assert_equal 3.5, payments[0][:interest_rate].to_f
    assert_equal Date.new(2023, 3, 1), payments[1][:payment_date]
    assert_equal 5.5, payments[1][:interest_rate].to_f
  end

  test "variable rate changes after maturity do not create extra segments" do
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan After Maturity",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: 3.5,
        term_months: 6,
        start_date: Date.new(2023, 1, 1)
      )
    loan = variable_loan.loan
    loan.add_variable_rate_change(Date.new(2025, 1, 1), 5.5)

    assert_equal 6, loan.amortization_schedule.payment_count
  end

  test "monthly payment uses the rate effective on the first payment date" do
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan First Payment Rate",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: 3.5,
        term_months: 360,
        start_date: Date.new(2023, 1, 1)
      )
    loan = variable_loan.loan
    loan.add_variable_rate_change(Date.new(2023, 1, 15), 5.5)

    assert_equal loan.amortization_schedule.payments.first[:payment_amount], loan.monthly_payment.amount
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

  test "rejects zero or negative term at the validation layer" do
    loan = Loan.new(rate_type: "fixed", interest_rate: 3.5, term_months: 0)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be greater than 0"
  end

  test "rejects a term months beyond the supported maximum" do
    loan = Loan.new(rate_type: "fixed", interest_rate: 3.5, term_months: Loan::MAX_TERM_MONTHS + 1)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be less than or equal to #{Loan::MAX_TERM_MONTHS}"
  end

  test "schedule is not amortizable for zero term" do
    zero_term_loan = Account.new \
      family: @family,
      name: "Zero Term Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.new(
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

  test "monthly payment is nil, not zero, when the loan is not amortizable" do
    no_rate_loan = Account.create! \
      family: @family,
      name: "No Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "fixed",
        interest_rate: nil,
        term_months: 360
      )

    schedule = no_rate_loan.loan.amortization_schedule
    assert_nil schedule.monthly_payment
  end

  test "a rate segment does not amortize as if the loan ended when the rate changes again" do
    # Same rate re-registered partway through the term, purely to force a
    # segment split with no change in rate value -- isolates the "amortize
    # over this segment's own length" bug from any rate-driven difference.
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan Long Segment",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: 3.5,
        term_months: 360,
        start_date: Date.new(2020, 1, 1)
      )
    loan = variable_loan.loan
    loan.add_variable_rate_change(loan.start_date + 300.months, 3.5)

    schedule = loan.amortization_schedule
    first_payment = schedule.payments.first

    # Segment 1 covers only 300 of the 360 payments, but the level payment
    # must still amortize the full 360-payment term (matching the fixed-rate
    # loan's payment at the same rate/principal/term), not a 300-payment
    # payoff -- which would be a substantially larger payment.
    assert_equal BigDecimal("2245.22"), first_payment[:payment_amount]
  end

  test "a rate-change segment landing in a short calendar month is not skipped" do
    # Feb 1 -> Mar 1 is 28-29 days, under the ~30.44-day average a single
    # 1.month duration division would round down to 0 payments and silently
    # drop this segment's payment from the schedule.
    variable_loan = Account.create! \
      family: @family,
      name: "Variable Loan Short Month",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        rate_type: "variable",
        interest_rate: 3.5,
        term_months: 360,
        start_date: Date.new(2023, 1, 1)
      )
    loan = variable_loan.loan
    loan.add_variable_rate_change(Date.new(2023, 3, 1), 4.5)

    schedule = loan.amortization_schedule
    payments = schedule.payments

    assert_equal 360, payments.length
    assert_equal Date.new(2023, 2, 1), payments[0][:payment_date]
    assert_equal 3.5, payments[0][:interest_rate].to_f
    assert_equal Date.new(2023, 3, 1), payments[1][:payment_date]
    assert_equal 4.5, payments[1][:interest_rate].to_f
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

  test "each payment amount equals principal plus interest" do
    @schedule.payments.each do |payment|
      assert_equal payment[:principal_payment] + payment[:interest_payment], payment[:payment_amount]
    end
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

  test "characterization golden master covers fixed-rate rows" do
    loan = accounts(:characterization_fixed).loan

    assert_characterized_schedule loan, [
      characterized_row(1, "2024-02-15", "12.0", "340.02", "330.02", "10.00", "1000.00", "669.98"),
      characterized_row(2, "2024-03-15", "12.0", "340.02", "333.32", "6.70", "669.98", "336.66"),
      characterized_row(3, "2024-04-15", "12.0", "340.03", "336.66", "3.37", "336.66", "0.00")
    ]
  end

  test "characterization golden master covers variable rate rows with two changes" do
    loan = accounts(:characterization_variable).loan

    assert_characterized_schedule loan, [
      characterized_row(1, "2024-02-01", "0.0", "333.33", "333.33", "0.00", "1000.00", "666.67"),
      characterized_row(2, "2024-03-01", "12.0", "338.34", "331.67", "6.67", "666.67", "335.00"),
      characterized_row(3, "2024-04-01", "0.0", "335.00", "335.00", "0.00", "335.00", "0.00")
    ]
  end

  test "characterization golden master covers zero-interest final settlement" do
    loan = accounts(:characterization_zero_interest).loan

    assert_characterized_schedule loan, [
      characterized_row(1, "2024-02-01", "0.0", "33.33", "33.33", "0.00", "100.00", "66.67"),
      characterized_row(2, "2024-03-01", "0.0", "33.33", "33.33", "0.00", "66.67", "33.34"),
      characterized_row(3, "2024-04-01", "0.0", "33.34", "33.34", "0.00", "33.34", "0.00")
    ]
  end

  test "characterization golden master covers a short one-period loan" do
    loan = accounts(:characterization_short).loan

    assert_characterized_schedule loan, [
      characterized_row(1, "2024-02-15", "12.0", "1010.00", "1000.00", "10.00", "1000.00", "0.00")
    ]
  end

  test "characterization golden master covers month-end clamping" do
    loan = accounts(:characterization_month_end).loan

    assert_characterized_schedule loan, [
      characterized_row(1, "2024-02-29", "0.0", "33.33", "33.33", "0.00", "100.00", "66.67"),
      characterized_row(2, "2024-03-29", "0.0", "33.33", "33.33", "0.00", "66.67", "33.34"),
      characterized_row(3, "2024-04-29", "0.0", "33.34", "33.34", "0.00", "33.34", "0.00")
    ]
  end

  # --- #36: which accrual the production read path runs -------------------
  #
  # The version bump to 3 shipped while `generate_schedule` still accrued
  # monthly, which would have invalidated every persisted row on deploy to
  # regenerate identical numbers. Pin the pairing so it cannot happen silently.
  test "the persisted schedule accrues monthly, and the algorithm version says so" do
    assert_equal false, Loan::AmortizationSchedule::SCHEDULE_DAILY_ACCRUAL
    assert_equal 2, Loan::AmortizationSchedule::ALGORITHM_VERSION,
      "ALGORITHM_VERSION must not advance past 2 while SCHEDULE_DAILY_ACCRUAL is false -- " \
      "the version is baked into the schedule signature, so bumping it rebuilds every " \
      "persisted row for every loan while producing identical numbers (#36)"
  end

  test "payments and an unqualified simulation are the same calculation" do
    schedule = accounts(:characterization_fixed).loan.amortization_schedule

    assert_equal schedule.payments, schedule.simulation.payments
  end

  test "daily accrual is a different calculation, and is not the one production runs" do
    schedule = accounts(:characterization_fixed).loan.amortization_schedule

    monthly = schedule.simulation(daily_accrual: false)
    daily = schedule.simulation(daily_accrual: true)

    assert_not_equal daily.total_interest, monthly.total_interest,
      "if these agree the daily path is not doing anything and this test proves nothing"
    assert_equal monthly.payments, schedule.payments,
      "production must run the monthly path while SCHEDULE_DAILY_ACCRUAL is false (#36)"
  end

  test "simulation returns an empty converged result for a non-amortizable loan" do
    loan = accounts(:characterization_fixed).loan
    loan.update!(term_months: nil)

    result = loan.amortization_schedule.simulation

    assert_empty result.payments
    assert result.converged?
  end

  test "characterization assertion fails on a deliberate one-cent mutation" do
    expected = characterized_row(1, "2024-02-01", "0.0", "33.33", "33.33", "0.00", "100.00", "66.67")
    mutated = expected.merge(payment_amount: BigDecimal("33.34"))

    assert_raises(Minitest::Assertion) { assert_equal expected, mutated }
  end

  private

    def characterized_row(number, date, rate, payment, principal, interest, beginning, ending)
      {
        payment_number: number,
        payment_date: Date.iso8601(date),
        interest_rate: BigDecimal(rate),
        payment_amount: BigDecimal(payment),
        principal_payment: BigDecimal(principal),
        interest_payment: BigDecimal(interest),
        beginning_balance: BigDecimal(beginning),
        ending_balance: BigDecimal(ending)
      }
    end

    def assert_characterized_schedule(loan, expected_rows)
      actual_rows = loan.amortization_schedule.payments.map do |row|
        row.slice(
          :payment_number,
          :payment_date,
          :interest_rate,
          :payment_amount,
          :principal_payment,
          :interest_payment,
          :beginning_balance,
          :ending_balance
        )
      end

      assert_equal expected_rows, actual_rows
      actual_rows.each_cons(2) do |current, following|
        assert_equal current[:ending_balance], following[:beginning_balance]
      end
      assert_equal BigDecimal("0"), actual_rows.last[:ending_balance]
    end
end
