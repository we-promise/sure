require "test_helper"

class Loan::AmortizationScheduleTest < ActiveSupport::TestCase
  setup do
    @loan = Loan.new(
      annuity_enabled: true,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      initial_balance: 300000,
      term_months: 360,
      rate_type: "fixed"
    )
  end

  test "generates fixed-rate annuity rows through payoff" do
    @loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    @account = create_account!(@loan, balance: 300000)

    schedule = Loan::AmortizationSchedule.new(@loan)
    rows = schedule.rows

    assert_equal 360, rows.size
    assert_equal Date.new(2024, 2, 1), rows.first.due_date
    assert_in_delta 300000, rows.first.opening_principal, 0.01
    assert_in_delta 1500, rows.first.interest, 0.01
    assert_in_delta 298.65, rows.first.scheduled_principal, 0.01
    assert_in_delta 1798.65, rows.first.scheduled_payment, 0.01
    assert_in_delta 0, rows.last.closing_principal, 0.01
    assert_in_delta 347515.44, schedule.total_interest, 0.01
    assert_equal Date.new(2054, 1, 1), schedule.payoff_date
  end

  test "generates zero-interest schedule" do
    @loan.initial_balance = 1200
    @loan.term_months = 12
    @loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 0)
    create_account!(@loan, balance: 1200)

    rows = Loan::AmortizationSchedule.new(@loan).rows

    assert_equal 12, rows.size
    assert_in_delta 100, rows.first.scheduled_payment, 0.01
    assert_in_delta 0, rows.first.interest, 0.01
    assert_in_delta 100, rows.first.scheduled_principal, 0.01
    assert_in_delta 0, rows.last.closing_principal, 0.01
  end

  test "recalculates payment at rate period transitions" do
    @loan.initial_balance = 120000
    @loan.term_months = 24
    @loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 3.0)
    @loan.loan_rate_periods.build(starts_on: Date.new(2025, 1, 1), annual_rate: 6.0)
    create_account!(@loan, balance: 120000)

    rows = Loan::AmortizationSchedule.new(@loan).rows

    assert_in_delta 5157.75, rows.first.scheduled_payment, 0.01
    assert_in_delta 5247.77, rows[11].scheduled_payment, 0.01
    assert_in_delta 0, rows.last.closing_principal, 0.01
  end

  test "uses payment override for real-world remortgage periods" do
    @loan.initial_balance = 120000
    @loan.term_months = 24
    @loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 3.0, payment_amount: 5300)
    create_account!(@loan, balance: 120000)

    rows = Loan::AmortizationSchedule.new(@loan).rows

    assert_in_delta 5300, rows.first.scheduled_payment, 0.01
    assert_in_delta 0, rows.last.closing_principal, 0.01
  end

  test "reports scheduled balance and variance against current balance" do
    @loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    @account = create_account!(@loan, balance: 250000)

    schedule = Loan::AmortizationSchedule.new(@loan, as_of: Date.new(2024, 2, 1))

    assert_in_delta 299701.35, schedule.scheduled_balance, 0.01
    assert_in_delta(-49701.35, schedule.balance_variance, 0.01)
  end

  test "reports remaining periods from the current schedule date" do
    @loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    create_account!(@loan, balance: 300000)

    schedule = Loan::AmortizationSchedule.new(@loan, as_of: Date.new(2024, 2, 1))

    assert_equal 359, schedule.remaining_periods
  end

  private
    def create_account!(loan, balance:)
      Account.create!(
        family: families(:dylan_family),
        name: "Annuity Mortgage",
        balance: balance,
        currency: "USD",
        accountable: loan
      )
    end
end
