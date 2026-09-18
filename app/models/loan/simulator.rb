class Loan
  # The period engine. Walks a payment schedule, charging interest and applying
  # payments, and returns a SimulationResult.
  #
  # It takes values and callables rather than a Loan, so the contracted schedule
  # and (later) a projection from today's balance can share one loop instead of
  # growing two implementations that drift.
  #
  # ## Accrual is monthly
  #
  # One interest charge per period, on the balance outstanding when the period
  # opened. Daily accrual is a different engine and is deliberately not here.
  #
  # ## Two rates, not one
  #
  # A period is bounded by two dates, and on a variable loan they can sit either
  # side of a rate change. Which rate applies depends on what is being asked:
  #
  #   * **Interest** for the period [previous payment date, this payment date)
  #     accrues at the rate in force when the period **opened**. A rate that
  #     becomes effective on this period's closing date belongs to the NEXT
  #     window, not to the month that has already run at the old rate.
  #   * **Payment sizing** uses the rate in force **on** the payment date, so a
  #     change effective on a payment date resizes that payment.
  #
  # Reading a single rate for both re-rates the period ending on the boundary --
  # the borrower is charged a rate that did not apply for any day of the month
  # being billed. Keeping them apart is the whole reason `accrual_rate_for` is
  # called twice with different dates below.
  #
  # Under monthly accrual a rate change *mid*-period cannot move that period's
  # interest: there is one charge, computed at the period's opening rate. It
  # takes effect from the following period. That is a property of monthly
  # accrual, not an approximation to be corrected here.
  class Simulator
    # Guards a runaway schedule: a hundred years of monthly payments. Refused
    # outright rather than truncated -- silently walking the first 1,200 of a
    # longer schedule returns totals and a payoff date describing a loan that
    # was never asked for, and loses the remaining balance without saying so.
    MAX_PERIODS = 1200

    PAYMENT_STRATEGIES = %i[reamortize hold].freeze

    # Built once: `monthly_rate` runs twice per period, up to MAX_PERIODS times
    # per simulation. The two-step division is kept as it was so results stay
    # bit-identical to the schedules already asserted in the tests.
    PERCENT = BigDecimal("100")
    MONTHS_PER_YEAR = BigDecimal("12")

    # How a period's interest is measured against a year.
    #
    # `thirty_360` is the default because it IS the flat 1/12 this engine has
    # always charged -- 30/360 reduces to 1/12 exactly -- so a loan that does
    # not choose a convention produces the schedule it produced before, row for
    # row. `actual_actual` is NOT a substitute for that: it charges 31/365 in
    # January and 28/365 in February, and only reaches 1/12 when a whole
    # calendar year is summed.
    DAY_COUNT_CONVENTIONS = %i[thirty_360 actual_365 actual_actual].freeze
    DEFAULT_DAY_COUNT_CONVENTION = :thirty_360
    DAYS_PER_YEAR = BigDecimal("365")
    DAYS_PER_LEAP_YEAR = BigDecimal("366")

    def initialize(
      starting_balance:,
      accrual_start_date:,
      payment_schedule:,
      accrual_rate_for:,
      currency_precision:,
      re_amortisation_events: nil,
      payment_strategy: :reamortize,
      settle_at_schedule_end: true,
      day_count_convention: DEFAULT_DAY_COUNT_CONVENTION
    )
      @starting_balance = BigDecimal(starting_balance.to_s)
      @accrual_start_date = accrual_start_date
      @payment_schedule = payment_schedule.to_a.freeze
      @accrual_rate_for = callable!(accrual_rate_for, :accrual_rate_for)
      @re_amortisation_events = callable!(
        re_amortisation_events || ->(_from, _to) { [] }, :re_amortisation_events
      )
      @currency_precision = currency_precision
      @payment_strategy = payment_strategy.to_sym
      @settle_at_schedule_end = settle_at_schedule_end
      @day_count_convention = (day_count_convention || DEFAULT_DAY_COUNT_CONVENTION).to_sym

      raise ArgumentError, "payment schedule must not be empty" if @payment_schedule.empty?
      if @payment_schedule.length > MAX_PERIODS
        raise ArgumentError,
          "payment schedule has #{@payment_schedule.length} periods (#{@payment_schedule.first} to #{@payment_schedule.last}), " \
          "more than the #{MAX_PERIODS} allowed"
      end
      unless PAYMENT_STRATEGIES.include?(@payment_strategy)
        raise ArgumentError, "unsupported payment strategy: #{@payment_strategy.inspect}"
      end
      unless DAY_COUNT_CONVENTIONS.include?(@day_count_convention)
        raise ArgumentError,
              "unsupported day-count convention: #{@day_count_convention.inspect} " \
              "(expected one of #{DAY_COUNT_CONVENTIONS.join(', ')})"
      end
    end

    def run
      balance = @starting_balance
      payments = []
      payment = nil
      previous_sizing_rate = nil
      (0...@payment_schedule.length).each do |index|
        break if balance <= 0

        payment_date = @payment_schedule[index]
        period_start = index.zero? ? @accrual_start_date : @payment_schedule[index - 1]

        # See the class comment: opening rate charges the period, closing rate
        # sizes the payment.
        #
        # The day count applies to the charge, not to the sizing. `level_payment`
        # is an annuity formula and assumes ONE constant periodic rate; a factor
        # that moves with the length of the month would differ every period, so
        # under :reamortize the payment would be recomputed every month and stop
        # being level. Sizing therefore stays on the nominal monthly rate, which
        # is also what the borrower's contracted payment is set from.
        accrual_annual = @accrual_rate_for.call(period_start)
        accrual_rate = accrual_factor(period_start, payment_date, accrual_annual)
        sizing_rate = monthly_rate(rate_on(payment_date))

        # Interest first, on the balance the period opened with: one charge
        # per period under monthly accrual. Sizing needs it when the two rates
        # differ, see below.
        interest = (balance * accrual_rate).round(@currency_precision)

        # Resize only when the sizing rate actually moves. Recomputing every
        # period would be arithmetically identical while the rate holds, but it
        # would also silently absorb a payment the borrower is contracted to,
        # which is what `:hold` exists to refuse.
        #
        # When the period straddles the change -- accrued at the old rate,
        # sized at the new -- the annuity formula alone over-covers this
        # period and the payment is not level to maturity (a final settlement
        # thousands short). The sizing is told what this period actually
        # charged so the figure covers it and amortises the rest evenly.
        if payment.nil? || (@payment_strategy == :reamortize && sizing_rate != previous_sizing_rate)
          payment = AmortizationMath.level_payment(
            balance: balance,
            monthly_rate: sizing_rate,
            remaining_payments: @payment_schedule.length - index,
            currency_precision: @currency_precision,
            # "Did the rate move mid-period?", asked of the rates themselves.
            # Comparing the derived factors would answer "yes" every month once
            # a day count is in play, because January and February differ by
            # length rather than by rate.
            first_period_interest: (interest if sizing_rate != monthly_rate(accrual_annual))
          )
        end
        previous_sizing_rate = sizing_rate

        final = (@settle_at_schedule_end && index == @payment_schedule.length - 1) ||
          payment >= balance + interest

        step = AmortizationMath.step(
          balance: balance,
          payment: payment,
          monthly_rate: accrual_rate,
          currency_precision: @currency_precision,
          final: final,
          interest: interest
        )

        # Two rates on the row, named for what each did: `interest_rate` is
        # the one the interest column was computed with, so a reader who
        # recomputes beginning_balance * rate / 12 gets this row's figure;
        # `sizing_rate` is the one the payment was sized at. They differ only
        # on a row whose period straddles a rate change.
        payments << {
          payment_number: index + 1,
          payment_date: payment_date,
          interest_rate: BigDecimal(@accrual_rate_for.call(period_start).to_s),
          sizing_rate: BigDecimal(rate_on(payment_date).to_s),
          **step
        }

        balance = step[:ending_balance]
      end

      SimulationResult.new(payments: payments, currency_precision: @currency_precision)
    end

    private
      # The contracted rate on a given payment date: a re-amortisation event
      # effective that day, otherwise whatever the rate curve says.
      def rate_on(date)
        event = re_amortisation_rates.reverse.find { |effective, _| effective <= date }
        event ? event.last : @accrual_rate_for.call(date)
      end

      def re_amortisation_rates
        @re_amortisation_rates ||= @re_amortisation_events
          .call(@payment_schedule.first, @payment_schedule.last)
          .map { |event| [ event.fetch(:date), event.fetch(:rate) ] }
          .sort_by(&:first)
      end

      # `annual_percentage` is whatever the caller's rate callable returned --
      # an Integer in the tests, a BigDecimal from RateResolver -- so the
      # coercion at this boundary stays.
      # 30/360 keeps the original two-step division untouched, so a default
      # loan's figures are bit-identical rather than merely close.
      def accrual_factor(period_start, period_end, annual_percentage)
        return monthly_rate(annual_percentage) if @day_count_convention == :thirty_360

        rate = BigDecimal(annual_percentage.to_s) / PERCENT
        days = BigDecimal((period_end - period_start).to_i.to_s)
        denominator =
          if @day_count_convention == :actual_actual
            Date.leap?(period_start.year) ? DAYS_PER_LEAP_YEAR : DAYS_PER_YEAR
          else
            DAYS_PER_YEAR
          end

        (rate * days) / denominator
      end

      def monthly_rate(annual_percentage)
        (BigDecimal(annual_percentage.to_s) / PERCENT) / MONTHS_PER_YEAR
      end

      def callable!(value, name)
        raise ArgumentError, "#{name} must respond to #call" unless value.respond_to?(:call)

        value
      end
  end
end
