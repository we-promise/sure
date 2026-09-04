require "test_helper"

class Loan::SimulatorTest < ActiveSupport::TestCase
  test "uses resolver values without reading a Loan" do
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: [ Date.new(2024, 2, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("101.00") }
    ).run

    assert result.converged?
    assert_equal BigDecimal("100.00"), result.payments.first[:payment_amount]
    assert_equal BigDecimal("100.00"), result.payments.first[:principal_payment]
    assert_equal BigDecimal("0.00"), result.payments.first[:ending_balance]
  end

  test "hold strategy keeps the payment and settles the final period" do
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: [ Date.new(2024, 1, 1), Date.new(2024, 2, 1), Date.new(2024, 3, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("40.00") }
    ).run

    assert result.converged?
    assert_equal [ BigDecimal("40.00"), BigDecimal("40.00"), BigDecimal("20.00") ], result.payments.map { |row| row[:payment_amount] }
    assert_equal BigDecimal("0.00"), result.balloon_amount
  end

  test "reamortize strategy resolves a new payment for each rate segment" do
    calls = []
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: [ Date.new(2024, 1, 1), Date.new(2024, 2, 1), Date.new(2024, 3, 1) ],
      rates: [ BigDecimal("0"), BigDecimal("12"), BigDecimal("12") ],
      payment_strategy: :reamortize,
      payment_amount_for: ->(rate:, balance:, remaining_payments:, payment_number:) do
        calls << [ rate, balance, remaining_payments, payment_number ]
        balance
      end
    ).run

    assert result.converged?
    assert_equal 2, calls.length
    assert_equal [ BigDecimal("0"), BigDecimal("12") ], calls.map(&:first)
    assert_equal [ 3, 2 ], calls.map { |call| call[2] }
  end

  test "re-amortisation events use the next payment while accrual remains date-resolved" do
    payment_dates = [ Date.new(2024, 1, 1), Date.new(2024, 2, 1), Date.new(2024, 3, 1) ]
    calls = []
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: payment_dates,
      rates: [ BigDecimal("3"), BigDecimal("3"), BigDecimal("3") ],
      payment_strategy: :reamortize,
      payment_amount_for: ->(rate:, balance:, remaining_payments:, payment_number:) do
        calls << [ rate, remaining_payments, payment_number ]
        balance
      end,
      re_amortisation_events: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 2, 15), rate: BigDecimal("12") } ]
      }
    ).run

    assert result.converged?
    assert_equal [ BigDecimal("3"), BigDecimal("12") ], calls.map(&:first)
    assert_equal [ 3, 1 ], calls.map { |call| call[1] }
  end

  test "passes the accrual stub boundaries to the interest resolver" do
    calls = []
    result = build_simulator(
      starting_balance: "100.00",
      starting_balance_as_of: Date.new(2024, 1, 1),
      accrual_start_date: Date.new(2024, 1, 15),
      payment_schedule: [ Date.new(2024, 2, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("101.00") },
      interest_for: ->(from_date:, to_date:, **_args) {
        calls << [ from_date, to_date ]
        BigDecimal("1.00")
      }
    ).run

    assert result.converged?
    assert_equal [ [ Date.new(2024, 1, 15), Date.new(2024, 2, 1) ] ], calls
    assert_equal BigDecimal("1.00"), result.payments.first[:interest_payment]
  end

  test "daily accrual is charged once and receives offset change points" do
    result = build_simulator(
      starting_balance: "1000.00",
      accrual_start_date: Date.new(2024, 1, 1),
      payment_schedule: [ Date.new(2024, 2, 1) ],
      rates: [ BigDecimal("12"), BigDecimal("12") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("1010.00") },
      daily_accrual: true,
      offset_for: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 1, 15), amount: BigDecimal("1000") } ]
      }
    ).run

    assert result.converged?
    assert_equal BigDecimal("4.60"), result.payments.first[:interest_payment]
  end

  test "daily accrual applies a mid-period rate change only from its effective date" do
    result = build_simulator(
      starting_balance: "100000.00",
      accrual_start_date: Date.new(2024, 2, 1),
      payment_schedule: [ Date.new(2024, 3, 1) ],
      rates: [ BigDecimal("3"), BigDecimal("3") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("100000.00") },
      daily_accrual: true,
      re_amortisation_events: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 2, 15), rate: BigDecimal("12") } ]
      },
      interest_for: nil
    ).run

    assert_equal BigDecimal("608.22"), result.payments.first[:interest_payment]
  end

  test "daily accrual applies an extra repayment at its effective date" do
    result = build_simulator(
      starting_balance: "1000.00",
      payment_schedule: [ Date.new(2024, 2, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("1000.00") },
      daily_accrual: true,
      extra_for: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 1, 15), amount: BigDecimal("100.00") } ]
      }
    ).run

    assert_equal BigDecimal("900.00"), result.payments.first[:beginning_balance]
    assert_equal BigDecimal("900.00"), result.payments.first[:payment_amount]
  end

  test "a rate change on a payment date affects the next period only" do
    result = build_simulator(
      starting_balance: "1000.00",
      payment_schedule: [ Date.new(2024, 2, 1), Date.new(2024, 3, 1), Date.new(2024, 4, 1) ],
      rates: [ BigDecimal("0"), BigDecimal("0"), BigDecimal("12") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("0.00") },
      daily_accrual: true,
      re_amortisation_events: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 3, 1), rate: BigDecimal("12") } ]
      }
    ).run

    assert_equal BigDecimal("0.00"), result.payments[0][:interest_payment]
    assert_equal BigDecimal("9.53"), result.payments[1][:interest_payment]
  end

  test "an extra repayment on a payment date is applied before payment" do
    result = build_simulator(
      starting_balance: "1000.00",
      payment_schedule: [ Date.new(2024, 2, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("1000.00") },
      daily_accrual: true,
      extra_for: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 2, 1), amount: BigDecimal("100.00") } ]
      }
    ).run

    assert_equal BigDecimal("900.00"), result.payments.first[:beginning_balance]
    assert_equal BigDecimal("900.00"), result.payments.first[:payment_amount]
  end

  test "extra repayment and offset movement on one date affect the next period" do
    result = build_simulator(
      starting_balance: "1000.00",
      payment_schedule: [ Date.new(2024, 2, 1), Date.new(2024, 3, 1), Date.new(2024, 4, 1) ],
      rates: [ BigDecimal("0"), BigDecimal("0"), BigDecimal("12") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("0.00") },
      daily_accrual: true,
      extra_for: ->(from_date, to_date) {
        next [] unless from_date < Date.new(2024, 3, 1) && Date.new(2024, 3, 1) <= to_date

        [ { date: Date.new(2024, 3, 1), amount: BigDecimal("100.00") } ]
      },
      offset_for: ->(from_date, to_date) {
        next [] unless from_date <= Date.new(2024, 3, 1) && Date.new(2024, 3, 1) < to_date

        [ { date: Date.new(2024, 3, 1), amount: BigDecimal("200.00") } ]
      }
    ).run

    assert_equal BigDecimal("900.00"), result.payments[2][:beginning_balance]
    assert_equal BigDecimal("7.13"), result.payments[2][:interest_payment]
  end

  test "reports a non-converged run with its remaining balloon" do
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: [ Date.new(2024, 1, 1), Date.new(2024, 2, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("40.00") },
      max_iterations: 1
    ).run

    assert_not result.converged?
    assert_nil result.payoff_date
    assert_equal BigDecimal("60.00"), result.balloon_amount
  end

  test "result and payment rows are immutable" do
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: [ Date.new(2024, 1, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("100.00") }
    ).run

    assert result.frozen?
    assert result.payments.frozen?
    assert result.payments.first.frozen?
    assert_raises(FrozenError) { result.payments.first[:payment_amount] = BigDecimal("0") }
  end

  test "event order is a fixed contract" do
    assert_equal %i[accrual extra_repayment offset_movement payment re_amortisation], Loan::Simulator::EVENT_ORDER
    assert Loan::Simulator::EVENT_ORDER.frozen?
  end

  test "requests extra and offset change points over each period range" do
    ranges = []
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: [ Date.new(2024, 1, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("100.00") },
      extra_for: ->(from_date, to_date) { ranges << [ :extra, from_date, to_date ] },
      offset_for: ->(from_date, to_date) { ranges << [ :offset, from_date, to_date ] }
    ).run

    assert result.converged?
    assert_equal [
      [ :extra, Date.new(2024, 1, 1), Date.new(2024, 1, 1) ],
      [ :offset, Date.new(2024, 1, 1), Date.new(2024, 1, 1) ]
    ], ranges
  end

  test "caps iterations at the loan maximum term" do
    payment_dates = Array.new(Loan::Simulator::MAX_TERM_MONTHS + 1) do |index|
      Date.new(2024, 1, 1) >> index
    end

    result = build_simulator(
      starting_balance: "1201.00",
      payment_schedule: payment_dates,
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("1.00") }
    ).run

    assert_not result.converged?
    assert_equal Loan::Simulator::MAX_TERM_MONTHS, result.payment_count
    assert_equal BigDecimal("1.00"), result.balloon_amount
  end

  private

    def build_simulator(
      starting_balance:,
      starting_balance_as_of: Date.new(2024, 1, 1),
      accrual_start_date: Date.new(2024, 1, 1),
      payment_schedule:,
      rates: nil,
      payment_strategy:,
      payment_amount_for:,
      interest_for: nil,
      daily_accrual: false,
      max_iterations: nil,
      extra_for: nil,
      offset_for: nil,
      re_amortisation_events: nil
    )
      rates ||= Array.new(payment_schedule.length, BigDecimal("0"))
      rate_index = 0

      Loan::Simulator.new(
        starting_balance: starting_balance,
        starting_balance_as_of: starting_balance_as_of,
        accrual_start_date: accrual_start_date,
        payment_schedule: payment_schedule,
        accrual_rate_for: ->(_date) {
          rate = rates[rate_index]
          rate_index += 1
          rate
        },
        re_amortisation_events: re_amortisation_events || ->(_from_date, _to_date) { [] },
        payment_strategy: payment_strategy,
        payment_amount_for: payment_amount_for,
        interest_for: interest_for,
        daily_accrual: daily_accrual,
        max_iterations: max_iterations,
        extra_for: extra_for,
        offset_for: offset_for,
        currency_precision: 2
      )
    end
end
