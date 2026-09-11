require "test_helper"

class Loan::SimulatorTest < ActiveSupport::TestCase
  # 12 monthly payments through 2026.
  SCHEDULE = (1..12).map { |n| Date.new(2026, 1, 1) >> n }.freeze

  test "runs one payment per scheduled date and amortises to zero" do
    result = run_simulation(starting_balance: 12_000, rate: 6)

    assert_equal 12, result.payment_count
    assert_equal BigDecimal("0"), result.payments.last[:ending_balance]
    assert_equal Date.new(2027, 1, 1), result.payoff_date
  end

  test "principal payments sum to the starting balance" do
    result = run_simulation(starting_balance: 12_000, rate: 6)

    assert_equal BigDecimal("12000"),
      result.payments.sum(BigDecimal("0")) { |p| p[:principal_payment] }
  end

  # Every run in this engine clears the balance: the level payment is sized
  # from the balance and the periods remaining, and the final period settles
  # exactly. Pinned so that a later change which CAN leave a balance
  # outstanding -- a projection holding a contracted payment against a
  # different balance -- has to confront this test rather than slip past it.
  test "the final period settles the balance exactly, whatever the rounding" do
    [ [ 12_000, 6 ], [ 10, 0 ], [ 999_999, 17.25 ], [ 1, 3.5 ] ].each do |balance, rate|
      result = run_simulation(starting_balance: balance, rate: rate)

      assert_equal BigDecimal("0"), result.payments.last[:ending_balance],
        "#{balance} at #{rate}% left a balance outstanding"
      assert_equal BigDecimal(balance.to_s),
        result.payments.sum(BigDecimal("0")) { |p| p[:principal_payment] },
        "#{balance} at #{rate}% did not repay its principal exactly"
    end
  end

  # THE behaviour this engine exists for, and the one #2984's single-rate loop
  # cannot express. Asserted here rather than in #104 because it is a property
  # of the simulator, not of how a Loan stores its rates.
  #
  # Interest for a period accrues at the rate in force when the period OPENED.
  # A rate effective on the period's closing date belongs to the next window --
  # the month being billed ran entirely at the old rate.
  test "interest accrues at the rate in force when the period opened, not when it closed" do
    change_date = Date.new(2026, 4, 1)
    rate_for = ->(date) { date < change_date ? 6 : 24 }

    result = Loan::Simulator.new(
      starting_balance: 12_000,
      accrual_start_date: Date.new(2026, 1, 1),
      payment_schedule: SCHEDULE,
      accrual_rate_for: rate_for,
      currency_precision: 2
    ).run

    # The period closing ON the change date (1 Mar -> 1 Apr) ran entirely at 6%.
    closing_on_change = result.payments.find { |p| p[:payment_date] == change_date }
    beginning = closing_on_change[:beginning_balance]
    assert_equal (beginning * BigDecimal("6") / 100 / 12).round(2), closing_on_change[:interest_payment],
      "the month ending on the rate change must be billed at the old rate"

    # The next period (1 Apr -> 1 May) opened at 24% and is billed at it.
    following = result.payments.find { |p| p[:payment_date] == Date.new(2026, 5, 1) }
    assert_equal (following[:beginning_balance] * BigDecimal("24") / 100 / 12).round(2),
      following[:interest_payment],
      "the month opening on the rate change must be billed at the new rate"
  end

  test "reamortize resizes the payment when the rate moves; hold does not" do
    change_date = Date.new(2026, 4, 1)
    rate_for = ->(date) { date < change_date ? 6 : 24 }

    reamortized, held = %i[reamortize hold].map do |strategy|
      Loan::Simulator.new(
        starting_balance: 12_000,
        accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: SCHEDULE,
        accrual_rate_for: rate_for,
        currency_precision: 2,
        payment_strategy: strategy
      ).run
    end

    first_payment = ->(r) { r.payments.first[:payment_amount] }
    after_change = ->(r) { r.payments.find { |p| p[:payment_date] == change_date }[:payment_amount] }

    assert_operator after_change.call(reamortized), :>, first_payment.call(reamortized),
      "a reamortising loan resizes its repayment upward when the rate rises"
    assert_equal first_payment.call(held), after_change.call(held),
      "a held loan keeps the contracted repayment through a rate change"
  end

  test "a re-amortisation event sizes the payment from its own effective date" do
    result = Loan::Simulator.new(
      starting_balance: 12_000,
      accrual_start_date: Date.new(2026, 1, 1),
      payment_schedule: SCHEDULE,
      accrual_rate_for: ->(_date) { 6 },
      re_amortisation_events: ->(_from, _to) { [ { date: Date.new(2026, 7, 1), rate: 24 } ] },
      currency_precision: 2
    ).run

    before = result.payments.find { |p| p[:payment_date] == Date.new(2026, 6, 1) }
    on     = result.payments.find { |p| p[:payment_date] == Date.new(2026, 7, 1) }

    assert_operator on[:payment_amount], :>, before[:payment_amount]
    # Two rates on the row that closes on the change: the period accrued at the
    # old rate and the payment was sized at the new one. `interest_rate` is the
    # one the interest column was computed with, so a reader who recomputes
    # beginning_balance * rate / 12 gets the row's own figure.
    assert_equal BigDecimal("24"), on[:sizing_rate]
    assert_equal BigDecimal("6"), on[:interest_rate]
    assert_equal (on[:beginning_balance] * on[:interest_rate] / 100 / 12).round(2), on[:interest_payment]
    assert_equal BigDecimal("6"), before[:interest_rate]
    # This run's accrual curve is flat at 6%; only the sizing events move, so
    # the rows after the change still accrue at 6 and size at 24.
    after = result.payments.find { |p| p[:payment_date] == Date.new(2026, 8, 1) }
    assert_equal BigDecimal("6"), after[:interest_rate]
    assert_equal BigDecimal("24"), after[:sizing_rate]
  end

  # The strategy a projection uses. Asked every period, and never re-sized off
  # the balance: a borrower ahead of schedule keeps paying what the contract
  # asks and finishes early, rather than being sized back onto the maturity.
  test "scheduled asks the callable every period and keeps its answer whatever the balance" do
    asked = []
    result = Loan::Simulator.new(
      starting_balance: 12_000,
      accrual_start_date: Date.new(2026, 1, 1),
      payment_schedule: SCHEDULE,
      accrual_rate_for: ->(_date) { 6 },
      currency_precision: 2,
      payment_strategy: :scheduled,
      payment_amount: ->(index:, balance:, **) { asked << [ index, balance ]; 2_000 },
      settle_at_schedule_end: false
    ).run

    assert_operator result.payment_count, :<, SCHEDULE.length, "2,000 a month clears 12,000 well inside a year"
    assert result.converged?
    assert_equal (0...result.payment_count).to_a, asked.map(&:first), "one call per period walked, in order"
    assert_equal result.payments.first[:ending_balance], asked[1].last, "each call sees the running balance"
    result.payments[0..-2].each do |payment|
      assert_equal BigDecimal("2000"), payment[:payment_amount],
        "the callable's answer is the payment, not a level payment re-derived from the balance"
    end
  end

  test "scheduled needs a callable, and the other strategies need a number" do
    build = ->(strategy, amount) {
      Loan::Simulator.new(
        starting_balance: 12_000, accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: SCHEDULE, accrual_rate_for: ->(_date) { 6 },
        currency_precision: 2, payment_strategy: strategy, payment_amount: amount
      )
    }

    assert_raises(ArgumentError) { build.call(:scheduled, 1_000) }
    assert_raises(ArgumentError) { build.call(:hold, ->(**) { 1_000 }) }
    assert_nothing_raised { build.call(:scheduled, ->(**) { 1_000 }) }
  end

  # A resized payment must stay level to maturity. The period that closes on a
  # rate change accrued at the OLD rate, but the annuity formula assumes every
  # remaining period, this one included, accrues at the new one; sized that
  # way, the payment over-covers the first period and the final settlement
  # becomes a discount of thousands. Codex's example on we-promise/sure#3473:
  # 500,000 over 24 months, 6% to 18% at month six, level 24,394.64, final
  # 19,156.02.
  test "a resized payment stays level through the final settlement" do
    change_date = Date.new(2026, 7, 1)
    [ change_date, Date.new(2026, 6, 20) ].each do |effective|
      result = Loan::Simulator.new(
        starting_balance: 500_000,
        accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: (1..24).map { |n| Date.new(2026, 1, 1) >> n },
        accrual_rate_for: ->(date) { date < effective ? 6 : 18 },
        re_amortisation_events: ->(_from, _to) { [ { date: effective, rate: 18 } ] },
        currency_precision: 2
      ).run

      resized = result.payments.find { |p| p[:payment_date] >= effective }[:payment_amount]
      assert_operator resized, :>, result.payments.first[:payment_amount]
      assert_in_delta resized, result.payments.last[:payment_amount], 1.0,
        "change effective #{effective}: the final payment must settle within rounding of the level payment"
      assert_equal BigDecimal("500000"),
        result.payments.sum(BigDecimal("0")) { |p| p[:principal_payment] }
    end
  end

  test "refuses an empty payment schedule rather than inventing a run" do
    error = assert_raises(ArgumentError) do
      Loan::Simulator.new(
        starting_balance: 1000, accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: [], accrual_rate_for: ->(_d) { 5 }, currency_precision: 2
      )
    end
    assert_match(/must not be empty/, error.message)
  end

  test "refuses an unknown payment strategy" do
    assert_raises(ArgumentError) do
      Loan::Simulator.new(
        starting_balance: 1000, accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: SCHEDULE, accrual_rate_for: ->(_d) { 5 },
        currency_precision: 2, payment_strategy: :guess
      )
    end
  end


  # Truncating a longer schedule would return totals and a payoff date for a
  # loan nobody asked for, and drop the remaining balance without saying so.
  test "refuses a schedule longer than it will walk rather than truncating it" do
    over = (1..(Loan::Simulator::MAX_PERIODS + 1)).map { |n| Date.new(2026, 1, 1) >> n }

    error = assert_raises(ArgumentError) do
      Loan::Simulator.new(
        starting_balance: 100_000, accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: over, accrual_rate_for: ->(_d) { 5 }, currency_precision: 2
      )
    end
    # The message carries the schedule it refused, so a report of it says
    # which run tripped the guard rather than only restating the limit.
    assert_match(/has 1201 periods \(2026-02-01 to 2126-02-01\), more than the 1200 allowed/, error.message)
  end

  private
    def run_simulation(starting_balance:, rate:, **overrides)
      Loan::Simulator.new(
        starting_balance: starting_balance,
        accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: SCHEDULE,
        accrual_rate_for: ->(_date) { rate },
        currency_precision: 2,
        **overrides
      ).run
    end
end
