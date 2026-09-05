require "test_helper"

class Loan::AmortizationScheduleTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @loan = @account.loan
  end

  def schedule
    Loan::AmortizationSchedule.new(@loan.reload)
  end

  # ---- availability ---------------------------------------------------------

  test "is unavailable without a payment and names the missing field" do
    @loan.update!(rate_type: "variable", scheduled_payment: nil, interest_rate: 5)

    assert_not schedule.available?
    assert_match(/monthly payment/, schedule.unavailable_reason)
  end

  # An unknown rate used to be read as 0%, which produced a confident,
  # interest-free schedule for a loan whose rate was simply never entered.
  test "is unavailable without an interest rate and names it" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "variable", interest_rate: nil, scheduled_payment: 500,
                  origination_date: nil)

    assert_not schedule.available?
    assert_match(/interest rate/, schedule.unavailable_reason)
  end

  test "an explicit zero rate is a real rate and still builds" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 500,
                  origination_date: nil)

    assert schedule.available?
    assert_nil schedule.unavailable_reason
  end

  test "is available from the live balance when no origination is recorded" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 500,
                  origination_date: nil)

    assert schedule.available?
    assert_not schedule.anchored_at_origination?
    assert_equal Date.current, schedule.start_date
  end

  # ---- the schedule itself --------------------------------------------------

  test "a zero-rate loan pays down by exactly the payment each month" do
    @account.update!(balance: 1_000)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100, origination_date: nil)

    balances = schedule.points.map(&:balance)

    assert_equal 1_000, balances.first
    assert_equal 900, balances[1]
    assert_equal 0, balances.last
    assert_equal 0, schedule.total_interest
  end

  test "an interest-bearing loan clears and accumulates interest" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "variable", interest_rate: 6, scheduled_payment: 500, origination_date: nil)

    assert_equal 0, schedule.points.last.balance
    assert schedule.total_interest.positive?
    assert schedule.payoff_date.present?
  end

  test "refuses to emit a schedule that never clears" do
    @account.update!(balance: 100_000)
    @loan.update!(rate_type: "variable", interest_rate: 12, scheduled_payment: 100, origination_date: nil)

    assert_operator schedule.points.size, :<, Loan::AmortizationSchedule::MAX_PERIODS
    assert_nil schedule.payoff_date, "a payment below the monthly interest clears nothing"
  end

  test "balance_on reads the schedule at a date" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100, origination_date: nil)

    assert_equal 1_200, schedule.balance_on(Date.current - 30)
    assert_equal 1_100, schedule.balance_on(Date.current.advance(months: 1))
    assert_equal 0, schedule.balance_on(Date.current.advance(years: 5))
  end

  # ---- the point of the exercise: measuring the recorded plateau -------------

  test "reports no comparison when the loan has no origination anchor" do
    @account.update!(balance: 1_200)
    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100, origination_date: nil)

    assert_empty schedule.divergences
  end

  test "quantifies the gap between a frozen recorded balance and the real amortization" do
    origination = Date.current.advance(months: -6).beginning_of_month
    @account.update!(balance: 1_000)

    Valuation.destroy_all if defined?(Valuation)
    @account.entries.destroy_all
    @account.entries.create!(
      name: "Opening",
      date: origination,
      amount: 1_000,
      currency: @account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    @loan.update!(rate_type: "variable", interest_rate: 0, scheduled_payment: 100,
                  origination_date: origination)

    # A loan repaid from a current account records nothing on the loan account,
    # so its stored balance never moves.
    (0..5).each do |month|
      @account.balances.create!(
        date: origination.advance(months: month),
        balance: 1_000,
        currency: @account.currency
      )
    end

    divergences = schedule.divergences

    assert divergences.any?, "there must be recorded months to compare"

    latest = divergences.last

    assert_equal 1_000, latest.recorded, "the stored balance stayed frozen"
    assert_operator latest.expected, :<, 1_000, "the terms imply real repayment"
    assert_operator latest.difference, :>, 0,
                    "a positive gap is the net worth curve understating progress"
  end
end
