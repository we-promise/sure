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

    # How the repayment behaves from one period to the next:
    #
    #   :reamortize  sized from the balance in front of it, and re-sized
    #                whenever the sizing rate moves -- what a lender does to a
    #                contracted schedule
    #   :hold        one figure, seeded or sized on the first period, held to
    #                the end whatever the rate does
    #   :scheduled   asked for every period from a callable, regardless of the
    #                balance -- what a projection uses to pay the CONTRACT's
    #                repayment against a balance that is no longer the
    #                contracted one, so a borrower who is ahead finishes early
    #                instead of being re-sized back onto the original maturity
    PAYMENT_STRATEGIES = %i[reamortize hold scheduled].freeze

    # Built once: `monthly_rate` runs twice per period, up to MAX_PERIODS times
    # per simulation. The two-step division is kept as it was so results stay
    # bit-identical to the schedules already asserted in the tests.
    PERCENT = BigDecimal("100")
    MONTHS_PER_YEAR = BigDecimal("12")

    def initialize(
      starting_balance:,
      accrual_start_date:,
      payment_schedule:,
      accrual_rate_for:,
      currency_precision:,
      re_amortisation_events: nil,
      payment_strategy: :reamortize,
      payment_amount: nil,
      settle_at_schedule_end: true
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
      # A caller-supplied repayment. Under :hold and :reamortize a number that
      # seeds the run; under :scheduled a callable, asked every period for the
      # amount the contract requires then -- see #run.
      @payment_amount =
        if payment_amount.respond_to?(:call) then payment_amount
        elsif payment_amount.nil? then nil
        else BigDecimal(payment_amount.to_s)
        end
      @settle_at_schedule_end = settle_at_schedule_end

      raise ArgumentError, "payment schedule must not be empty" if @payment_schedule.empty?
      if @payment_schedule.length > MAX_PERIODS
        raise ArgumentError,
          "payment schedule has #{@payment_schedule.length} periods (#{@payment_schedule.first} to #{@payment_schedule.last}), " \
          "more than the #{MAX_PERIODS} allowed"
      end
      unless PAYMENT_STRATEGIES.include?(@payment_strategy)
        raise ArgumentError, "unsupported payment strategy: #{@payment_strategy.inspect}"
      end
      if (@payment_strategy == :scheduled) != @payment_amount.respond_to?(:call)
        raise ArgumentError, ":scheduled takes a callable payment_amount; the other strategies take a number"
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
        accrual_rate = monthly_rate(@accrual_rate_for.call(period_start))
        sizing_rate = monthly_rate(rate_on(payment_date))

        # Interest first, on the balance the period OPENED with: one charge per
        # period under monthly accrual. Sizing needs it when the two rates
        # differ, see below.
        interest = (balance * accrual_rate).round(@currency_precision)

        if @payment_strategy == :scheduled
          # The contract's repayment for THIS period, whatever balance is in
          # front of it. Sizing from the balance would shrink a borrower who is
          # ahead back onto the original maturity; paying what the contract
          # asks is how they finish sooner.
          payment = BigDecimal(@payment_amount.call(
            index: index,
            balance: balance,
            sizing_rate: sizing_rate,
            remaining_payments: @payment_schedule.length - index
          ).to_s)
        else
          # Resize only when the sizing rate actually moves. Recomputing every
          # period would be arithmetically identical while the rate holds, but
          # it would also silently absorb a payment the borrower is contracted
          # to, which is what `:hold` exists to refuse.
          if payment.nil?
            # A supplied amount seeds the run -- a projection opens on the
            # repayment the borrower is contracted to, not one re-derived from
            # today's balance, which would make every loan look on track.
            payment = @payment_amount
          end
          # `previous_sizing_rate.nil?` guards the first period: there is no
          # earlier rate to have moved away from, so the opening rate is not a
          # rate CHANGE. Without it, a seeded repayment is overwritten on the
          # very first period it was supposed to govern.
          rate_moved = !previous_sizing_rate.nil? && sizing_rate != previous_sizing_rate
          # When the period straddles the change -- accrued at the old rate,
          # sized at the new -- the annuity formula alone over-covers this
          # period and the payment is not level to maturity (a final
          # settlement thousands short). The sizing is told what this period
          # actually charged so the figure covers it and amortises the rest
          # evenly.
          if payment.nil? || (@payment_strategy == :reamortize && rate_moved)
            payment = AmortizationMath.level_payment(
              balance: balance,
              monthly_rate: sizing_rate,
              remaining_payments: @payment_schedule.length - index,
              currency_precision: @currency_precision,
              first_period_interest: (interest if sizing_rate != accrual_rate)
            )
          end
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

      SimulationResult.new(
        payments: payments,
        converged: balance.zero?,
        balloon_amount: balance,
        currency_precision: @currency_precision
      )
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
      def monthly_rate(annual_percentage)
        (BigDecimal(annual_percentage.to_s) / PERCENT) / MONTHS_PER_YEAR
      end

      def callable!(value, name)
        raise ArgumentError, "#{name} must respond to #call" unless value.respond_to?(:call)

        value
      end
  end
end
