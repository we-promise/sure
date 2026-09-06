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

  # C4's guard: a run may not accrue on a balance it does not yet have.
  #
  # This test used to omit starting_balance:, so it raised
  # "missing keyword: :starting_balance" and never reached validate_boundaries!
  # at all -- and assert_raises' second argument is the FAILURE message, not a
  # matcher, so nothing noticed. It passed for the wrong reason.
  test "rejects an accrual period before the date of the starting balance" do
    error = assert_raises(ArgumentError) do
      build_simulator(
        starting_balance: "100.00",
        starting_balance_as_of: Date.new(2024, 2, 1),
        accrual_start_date: Date.new(2024, 1, 15),
        payment_schedule: [ Date.new(2024, 3, 1) ],
        payment_strategy: :hold,
        payment_amount_for: ->(**_args) { BigDecimal("100.00") }
      )
    end

    assert_equal "starting balance date must be on or before accrual start date", error.message,
      "the guard must be what raised -- not a missing keyword or a non-numeric value"
  end

  test "accepts a starting balance dated on the accrual start date" do
    assert_nothing_raised do
      build_simulator(
        starting_balance: "100.00",
        starting_balance_as_of: Date.new(2024, 1, 15),
        accrual_start_date: Date.new(2024, 1, 15),
        payment_schedule: [ Date.new(2024, 3, 1) ],
        payment_strategy: :hold,
        payment_amount_for: ->(**_args) { BigDecimal("100.00") }
      )
    end
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

  test "daily accrual passes the selected day-count convention to the engine" do
    result = build_simulator(
      starting_balance: "1000.00",
      accrual_start_date: Date.new(2024, 1, 1),
      payment_schedule: [ Date.new(2025, 1, 1) ],
      rates: [ BigDecimal("12") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("2000.00") },
      daily_accrual: true,
      day_count_convention: :actual_actual
    ).run

    assert_equal BigDecimal("120.00"), result.payments.first[:interest_payment]
  end

  # #25's worked example. 100,000 at 3%, changing to 12% effective 2024-02-15,
  # over 2024-02-01..2024-03-01 (29 days, leap February):
  #   14 days @ 3%  = 100000 * 14 * 3  / 100 / 365 = 115.0685
  #   15 days @ 12% = 100000 * 15 * 12 / 100 / 365 = 493.1507
  #                                                = 608.2192 -> 608.22
  # Applying 12% across all 29 days gives 953.42, a 56.8% overstatement.
  #
  # Driven by the ACCRUAL clock alone -- no re-amortisation event -- which is
  # what makes C7 and C8 separable.
  test "daily accrual applies a mid-period rate change only from its effective date" do
    result = build_simulator(
      starting_balance: "100000.00",
      accrual_start_date: Date.new(2024, 2, 1),
      payment_schedule: [ Date.new(2024, 3, 1) ],
      rates: [ BigDecimal("3"), BigDecimal("3") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("100000.00") },
      daily_accrual: true,
      accrual_rate_changes: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 2, 15), rate: BigDecimal("12") } ]
      },
      interest_for: nil
    ).run

    assert_equal BigDecimal("608.22"), result.payments.first[:interest_payment]
  end

  # C7 and C8 are two clocks. These two tests move one without the other; if
  # either input silently fed the other, one of them would fail.
  test "the accrual clock moves interest without resizing the contracted payment" do
    sizing_rates = []
    result = build_simulator(
      starting_balance: "100000.00",
      accrual_start_date: Date.new(2024, 2, 1),
      payment_schedule: [ Date.new(2024, 3, 1), Date.new(2024, 4, 1) ],
      rates: [ BigDecimal("3"), BigDecimal("3") ],
      payment_strategy: :reamortize,
      payment_amount_for: ->(rate:, **_args) {
        sizing_rates << rate
        BigDecimal("0.00")
      },
      daily_accrual: true,
      accrual_rate_changes: ->(from_date, to_date) {
        next [] unless from_date <= Date.new(2024, 2, 15) && Date.new(2024, 2, 15) < to_date

        [ { date: Date.new(2024, 2, 15), rate: BigDecimal("12") } ]
      }
    ).run

    assert_equal BigDecimal("608.22"), result.payments.first[:interest_payment],
      "the accrual clock must segment interest at the effective date (C7)"
    assert_equal [ BigDecimal("3") ], sizing_rates.uniq,
      "the payment must still be sized at the contracted rate -- the accrual clock is not the payment clock (C8)"
  end

  test "the payment clock resizes the payment without re-segmenting accrual" do
    sizing_rates = []
    result = build_simulator(
      starting_balance: "100000.00",
      accrual_start_date: Date.new(2024, 2, 1),
      payment_schedule: [ Date.new(2024, 3, 1), Date.new(2024, 4, 1) ],
      rates: [ BigDecimal("3"), BigDecimal("3") ],
      payment_strategy: :reamortize,
      payment_amount_for: ->(rate:, **_args) {
        sizing_rates << rate
        BigDecimal("0.00")
      },
      daily_accrual: true,
      re_amortisation_events: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 3, 1), rate: BigDecimal("12") } ]
      }
    ).run

    assert_includes sizing_rates, BigDecimal("12"),
      "the payment clock must resize the payment from the first payment date on or after the change (C8, C10)"

    # NOT asserted here, and open on #25: the period ENDING 2024-03-01 still
    # accrues at 12%, because the accrual base rate is still the
    # payment-sizing rate rather than the accrual rate at period start.
    # C10 says the accrual clock includes the effective date, so 12% should
    # apply from 2024-03-01 -- to the NEXT period, not the one that ends on it.
    # Asserting the corrected figure here would fail; asserting the current one
    # would pin a suspected defect. Neither belongs in a green suite.
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

  # REWRITTEN for #48. This test's NAME always described the correct behaviour;
  # its assertions described the defect. It asserted 9.53 on payments[1] -- the
  # period 2024-02-01..2024-03-01, which ran entirely at 0% -- because the
  # accrual base was re-read from the payment-sizing rate each period, so a
  # change effective ON 2024-03-01 retroactively re-rated the month that ENDED
  # on it.
  #
  # C10: the accrual clock includes the effective date. Accrual windows are
  # half-open, so 12% from 2024-03-01 belongs to [Mar 1, Apr 1) -- 31 days at
  # 12% on 1000 = 10.19 -- and February keeps the old rate.
  #
  # Both clocks are driven here, as RateResolver does in production: the payment
  # clock resizes the 2024-03-01 payment (C8/C10), the accrual clock moves
  # accrual from the same date.
  test "a rate change on a payment date affects the next period only" do
    change = ->(_from_date, _to_date) { [ { date: Date.new(2024, 3, 1), rate: BigDecimal("12") } ] }

    result = build_simulator(
      starting_balance: "1000.00",
      payment_schedule: [ Date.new(2024, 2, 1), Date.new(2024, 3, 1), Date.new(2024, 4, 1) ],
      rates: [ BigDecimal("0"), BigDecimal("0"), BigDecimal("12") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("0.00") },
      daily_accrual: true,
      re_amortisation_events: change,
      accrual_rate_changes: change
    ).run

    assert_equal BigDecimal("0.00"), result.payments[0][:interest_payment],
      "2024-01-01..02-01 ran at 0%"
    assert_equal BigDecimal("0.00"), result.payments[1][:interest_payment],
      "2024-02-01..03-01 ran entirely at 0% -- a rate effective ON 03-01 must not re-rate it (C10, #48)"
    assert_equal BigDecimal("10.19"), result.payments[2][:interest_payment],
      "2024-03-01..04-01 is 31 days at 12% on 1000"
  end

  # #48's acceptance criterion: both halves of the boundary in one assertion.
  # A rate change effective ON a payment date resizes THAT payment (C8/C10) and
  # leaves the PRECEDING period's interest at the old rate (C10 accrual side).
  # Before the fix these were the same rate, so one of the two had to be wrong.
  test "a rate change on a payment date resizes that payment and leaves the previous period alone" do
    change = ->(_from_date, _to_date) { [ { date: Date.new(2024, 3, 1), rate: BigDecimal("12") } ] }
    sizing_rates = []

    result = build_simulator(
      starting_balance: "1000.00",
      payment_schedule: [ Date.new(2024, 2, 1), Date.new(2024, 3, 1), Date.new(2024, 4, 1) ],
      rates: [ BigDecimal("0"), BigDecimal("0"), BigDecimal("0") ],
      payment_strategy: :reamortize,
      payment_amount_for: ->(rate:, **_args) {
        sizing_rates << rate
        BigDecimal("0.00")
      },
      daily_accrual: true,
      re_amortisation_events: change,
      accrual_rate_changes: change
    ).run

    assert_includes sizing_rates, BigDecimal("12"),
      "the payment clock must resize from the first payment date on or after the change (C8, C10)"
    assert_equal BigDecimal("0.00"), result.payments[1][:interest_payment],
      "the period ENDING on the change date must keep the old rate (C10, #48)"
    assert_equal BigDecimal("10.19"), result.payments[2][:interest_payment],
      "the period STARTING on the change date takes the new rate"
  end

  # The first-payment boundary, from the review on #59. A change effective on
  # the FIRST payment date is already in segment 1, so seeding the carried
  # accrual rate from segment[:rate] would accrue the opening period at the new
  # rate -- the #48 defect surviving at the one boundary the carry cannot reach.
  test "a rate change on the first payment date leaves the opening period at the old rate" do
    change = ->(_from_date, _to_date) { [ { date: Date.new(2024, 2, 1), rate: BigDecimal("12") } ] }

    result = build_simulator(
      starting_balance: "1000.00",
      accrual_start_date: Date.new(2024, 1, 1),
      payment_schedule: [ Date.new(2024, 2, 1), Date.new(2024, 3, 1) ],
      # rates[0] is the OLD rate, in force through the opening period.
      rates: [ BigDecimal("0"), BigDecimal("12") ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("0.00") },
      daily_accrual: true,
      re_amortisation_events: change,
      accrual_rate_changes: change
    ).run

    assert_equal BigDecimal("0.00"), result.payments[0][:interest_payment],
      "2024-01-01..02-01 ran at the old 0% -- a change effective ON 02-01 must not re-rate it"
    assert_equal BigDecimal("9.53"), result.payments[1][:interest_payment],
      "2024-02-01..03-01 is 29 days at 12% on 1000"
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
      },
      # The accrual clock has to be driven explicitly since #25 separated it
      # from the payment clock; `rates:` only sizes payments.
      accrual_rate_changes: ->(_from_date, _to_date) {
        [ { date: Date.new(2024, 3, 1), rate: BigDecimal("12") } ]
      }
    ).run

    assert_equal BigDecimal("900.00"), result.payments[2][:beginning_balance]
    assert_equal BigDecimal("7.13"), result.payments[2][:interest_payment],
      "31 days at 12% on 900 less a 200 offset"
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

  # EVENT_ORDER is now dispatched through, not merely declared. This is the
  # assertion with teeth: an event the accrual loop does not handle must raise
  # rather than be silently skipped, so the constant cannot gain a member that
  # the calculation quietly ignores.
  #
  # Honest limitation, recorded on #25: REORDERING the three intra-day events
  # does not change any figure, because rate, balance and offset are
  # independent variables applied at the same instant. Only the literal
  # assertion above catches a reorder. Ordering becomes numerically meaningful
  # when the events interact -- e.g. once C6's end-of-day semantics land.
  test "an event in EVENT_ORDER with no handler raises rather than being skipped" do
    original = Loan::Simulator::EVENT_ORDER
    Loan::Simulator.send(:remove_const, :EVENT_ORDER)
    Loan::Simulator.const_set(:EVENT_ORDER, (original + [ :unhandled_event ]).freeze)

    error = assert_raises(ArgumentError) do
      build_simulator(
        starting_balance: "1000.00",
        payment_schedule: [ Date.new(2024, 2, 1) ],
        payment_strategy: :hold,
        payment_amount_for: ->(**_args) { BigDecimal("1000.00") },
        daily_accrual: true
      ).run
    end

    assert_match(/unhandled event in EVENT_ORDER/, error.message)
  ensure
    Loan::Simulator.send(:remove_const, :EVENT_ORDER)
    Loan::Simulator.const_set(:EVENT_ORDER, original)
  end

  test "requests extra and offset change points over each period range" do
    ranges = []
    result = build_simulator(
      starting_balance: "100.00",
      payment_schedule: [ Date.new(2024, 1, 1) ],
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("100.00") },
      # These record the ranges they are asked about and return no changes.
      # Returning the accumulator (which is what this test used to do) only
      # went unnoticed while the simulator discarded the return value -- it
      # now consumes it, which is the point of #25.
      extra_for: ->(from_date, to_date) { ranges << [ :extra, from_date, to_date ]; [] },
      offset_for: ->(from_date, to_date) { ranges << [ :offset, from_date, to_date ]; [] }
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
      day_count_convention: Loan::InterestAccrual::DEFAULT_DAY_COUNT_CONVENTION,
      max_iterations: nil,
      extra_for: nil,
      offset_for: nil,
      re_amortisation_events: nil,
      accrual_rate_changes: nil
    )
      rates ||= Array.new(payment_schedule.length, BigDecimal("0"))

      Loan::Simulator.new(
        starting_balance: starting_balance,
        starting_balance_as_of: starting_balance_as_of,
        accrual_start_date: accrual_start_date,
        payment_schedule: payment_schedule,
        # A genuine function of date: rates[i] is the rate for the period
        # ending at payment_schedule[i], and any date at or before the first
        # payment resolves to rates[0]. The previous version counted calls,
        # which silently mis-answered as soon as the simulator asked about a
        # date other than a payment date -- e.g. accrual_start_date.
        accrual_rate_for: ->(date) {
          index = payment_schedule.index { |scheduled| scheduled >= date }
          rates[index || payment_schedule.length - 1]
        },
        re_amortisation_events: re_amortisation_events || ->(_from_date, _to_date) { [] },
        accrual_rate_changes: accrual_rate_changes,
        payment_strategy: payment_strategy,
        payment_amount_for: payment_amount_for,
        interest_for: interest_for,
        daily_accrual: daily_accrual,
        day_count_convention: day_count_convention,
        max_iterations: max_iterations,
        extra_for: extra_for,
        offset_for: offset_for,
        currency_precision: 2
      )
    end
end
