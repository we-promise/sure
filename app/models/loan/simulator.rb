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

    # What the term changes dated inside one period do to it.
    #
    #   balance            the balance the period charges interest on
    #   accrual_start      where that charge starts: the period's opening, or
    #                      the date of a balance confirmed part-way through
    #   closing_reduction  repaid on the payment date, after the charge
    #   closing_balance    a balance confirmed for the payment date itself
    #   payment            the instalment the lender set
    #   payment_set_on     the date of the change that set it
    #   resize             re-amortise this payment
    #   payment_next       the instalment the lender set from the next payment
    #   resize_next        re-amortise the next payment
    #   any                a term change is dated in the period
    PeriodChanges = Struct.new(
      :balance, :accrual_start, :closing_reduction, :closing_balance, :payment, :payment_set_on, :resize,
      :payment_next, :resize_next, :any,
      keyword_init: true
    )

    def initialize(
      starting_balance:,
      accrual_start_date:,
      payment_schedule:,
      accrual_rate_for:,
      currency_precision:,
      re_amortisation_events: nil,
      payment_strategy: :reamortize,
      payment_amount: nil,
      settle_at_schedule_end: true,
      day_count_convention: DEFAULT_DAY_COUNT_CONVENTION,
      term_changes: [],
      payment_grace_days: 0,
      first_period_interest: nil
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
      @day_count_convention = (day_count_convention || DEFAULT_DAY_COUNT_CONVENTION).to_sym
      # Recorded changes to the contract, as {date:, extra_repayment:, balance:,
      # payment:} with nil for what a change leaves alone. See #period_changes.
      @term_changes = Array(term_changes)
        .filter_map { |change| normalize_term_change(change) }
        .sort_by { |change| change[:date] }
        .freeze
      @payment_grace_days = payment_grace_days.to_i
      # What the first period still charges, when the caller knows better than
      # a full period on the starting balance: a projection that opens inside
      # a period a term change already shaped.
      @first_period_interest = first_period_interest.nil? ? nil : BigDecimal(first_period_interest.to_s)

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
      if @term_changes.any? && @payment_strategy != :reamortize
        raise ArgumentError, "term changes need the :reamortize payment strategy"
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
      resize_pending = false
      payment_pending = nil
      lender_payment_in_force = false
      (0...@payment_schedule.length).each do |index|
        break if balance <= 0

        payment_date = @payment_schedule[index]
        period_start = index.zero? ? @accrual_start_date : @payment_schedule[index - 1]

        # Term changes dated in this period. Without any, `changes` carries the
        # balance and the period's opening unchanged. A balance confirmed on
        # the previous payment date is already in `balance`; what it left for
        # this payment is the pending payment or resize, which a change dated
        # in this period overrides.
        changes = period_changes(index, balance)
        opening_adjustment = changes.balance - balance
        balance = changes.balance
        accrual_start = changes.accrual_start
        resize = changes.resize || (resize_pending && changes.payment.nil?)
        lender_payment = changes.payment || (payment_pending unless changes.resize)
        lender_payment_set_on = changes.payment ? changes.payment_set_on : period_start
        resize_pending = changes.resize_next
        payment_pending = changes.payment_next

        # See the class comment: opening rate charges the period, closing rate
        # sizes the payment.
        #
        # The day count applies to the charge, not to the sizing. `level_payment`
        # is an annuity formula and assumes ONE constant periodic rate; a factor
        # that moves with the length of the month would differ every period, so
        # under :reamortize the payment would be recomputed every month and stop
        # being level. Sizing therefore stays on the nominal monthly rate, which
        # is also what the borrower's contracted payment is set from.
        accrual_annual = @accrual_rate_for.call(accrual_start)
        accrual_rate = accrual_factor(accrual_start, payment_date, accrual_annual, full_period: accrual_start == period_start)
        sizing_rate = monthly_rate(rate_on(payment_date))

        # Interest first, on the balance the period OPENED with: one charge per
        # period under monthly accrual. Sizing needs it when the two rates
        # differ, see below.
        interest = (balance * accrual_rate).round(@currency_precision)
        interest = @first_period_interest if index.zero? && @first_period_interest

        # An extra repayment on the payment date comes off after the charge, so
        # the payment is sized and applied against what is left.
        closing_reduction = [ changes.closing_reduction, balance ].min
        amortised_balance = balance - closing_reduction
        # The plain annuity formula assumes this period charges
        # `amortised_balance` for a full period at the sizing rate.
        irregular_charge = closing_reduction.positive? || accrual_start != period_start

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
          # The lender's own figure holds until the rate moves or another
          # term change says otherwise. A rate that moved after the lender set
          # the figure is such a move, and the payment is re-sized.
          lender_payment_holds = lender_payment && rate_on(payment_date) == rate_on(lender_payment_set_on)
          lender_payment_lapsed = lender_payment && !lender_payment_holds

          if payment.nil? || (@payment_strategy == :reamortize && (rate_moved || resize || lender_payment_lapsed))
            payment = AmortizationMath.level_payment(
              balance: amortised_balance,
              monthly_rate: sizing_rate,
              remaining_payments: @payment_schedule.length - index,
              currency_precision: @currency_precision,
              # "Did the rate move mid-period?", asked of the rates themselves.
              # Comparing the derived factors would answer "yes" every month once
              # a day count is in play, because January and February differ by
              # length rather than by rate.
              first_period_interest: (interest if irregular_charge || sizing_rate != monthly_rate(accrual_annual))
            )
            lender_payment_in_force = false
          end
          if lender_payment_holds
            payment = lender_payment
            lender_payment_in_force = true
          end
        end
        previous_sizing_rate = sizing_rate

        # An extra repayment that clears the balance leaves only the period's
        # interest to settle.
        final = (@settle_at_schedule_end && index == @payment_schedule.length - 1) ||
          amortised_balance.zero? || payment >= amortised_balance + interest

        step = AmortizationMath.step(
          balance: amortised_balance,
          payment: payment,
          monthly_rate: accrual_rate,
          currency_precision: @currency_precision,
          final: final,
          interest: interest
        )

        # Two rates on the row, named for what each did: `interest_rate` is
        # the one the interest column was computed with, so a reader who
        # recomputes the charge from beginning_balance, this rate and the
        # period's day count (a flat twelfth under thirty_360) gets this row's
        # figure;
        # `sizing_rate` is the one the payment was sized at. They differ only
        # on a row whose period straddles a rate change.
        row = {
          payment_number: index + 1,
          payment_date: payment_date,
          interest_rate: BigDecimal(accrual_annual.to_s),
          sizing_rate: BigDecimal(rate_on(payment_date).to_s),
          # `beginning_balance` is the balance the period charged interest on.
          **step.merge(beginning_balance: balance.round(@currency_precision))
        }

        balance = step[:ending_balance]
        balance_adjustment = opening_adjustment - closing_reduction

        # A balance confirmed for the payment date is the balance after that
        # day's payment, whatever the row above worked out.
        if changes.closing_balance
          balance_adjustment += changes.closing_balance - balance
          balance = changes.closing_balance
          row[:ending_balance] = balance
        end

        # What term changes moved the balance by in this row, on top of the
        # principal the payment repaid, how much of that was repaid on the
        # payment date after the period's charge, and the factor the period
        # charged its balance at. A row that no term change reaches carries
        # none of these keys and is unchanged.
        row[:balance_adjustment] = balance_adjustment unless balance_adjustment.zero?
        row[:repaid_after_charge] = closing_reduction if closing_reduction.positive?
        row[:accrual_factor] = accrual_rate if changes.any
        # The payment of this row is one the lender set, not one sized here.
        row[:lender_payment] = true if lender_payment_in_force
        payments << row
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

      # The day-count definition lives in AmortizationMath so the schedule and
      # the ledger replay cannot charge a period differently.
      def accrual_factor(period_start, period_end, annual_percentage, full_period: true)
        AmortizationMath.accrual_factor(
          annual_percentage: annual_percentage,
          period_start: period_start,
          period_end: period_end,
          day_count_convention: @day_count_convention,
          full_period: full_period
        )
      end

      # Folds the term changes dated in a period into what the period does
      # with them, oldest first. A period runs from the previous payment date
      # (exclusive) to its own (inclusive). A change dated on the day the
      # schedule opens is left out: that day's balance is the opening balance.
      #
      # The rules are the ledger replay's, so a borrower who pays this
      # schedule and records the same events in the ledger lands on the same
      # balance:
      #
      #   * An extra repayment is what a linked transfer is there. Dated
      #     within the grace days after the period opened, it lowers the
      #     balance the period charges interest on. Later in the period, or on
      #     the payment date, the period still charges the balance it opened
      #     with and the repayment comes off on the payment date.
      #   * A confirmed balance is what a balance update is there. It replaces
      #     the balance on its own date. Part-way through a period, the charge
      #     runs from that date on that balance, and anything recorded earlier
      #     in the period is behind it. On a payment date it is the balance
      #     after that day's payment.
      #
      # The payment follows the change: the lender's figure when the change
      # carries one, otherwise re-amortised over the periods left. Both apply
      # from the first payment on or after the change. A balance confirmed for
      # a payment date changes the payment from the next one, because that
      # day's payment is already behind it.
      #
      # The match with the replay has three limits. The replay carries unpaid
      # interest without charging interest on it, so a payment below the
      # period's interest diverges; the loan form refuses one. A linked
      # transfer inside the grace days also pays the instalment's insurance
      # premium, so with a premium the replay charges that period on a balance
      # higher by the premium. And an extra repayment above the balance ends
      # the schedule at zero, while the replay keeps the excess as a credit.
      def period_changes(index, balance)
        period_start = index.zero? ? @accrual_start_date : @payment_schedule[index - 1]
        payment_date = @payment_schedule[index]
        folded = PeriodChanges.new(
          balance: balance, accrual_start: period_start, closing_reduction: BigDecimal("0"),
          closing_balance: nil, payment: nil, payment_set_on: nil, resize: false,
          payment_next: nil, resize_next: false, any: false
        )

        term_changes_in(index).each do |change|
          folded.any = true
          on_payment_date = change[:date] == payment_date

          if change[:balance]
            if on_payment_date
              folded.closing_balance = change[:balance]
            else
              folded.balance = change[:balance]
              folded.accrual_start = change[:date]
              folded.closing_reduction = BigDecimal("0")
            end
          elsif change[:extra_repayment]
            if !on_payment_date && folded.accrual_start == period_start && grace_day?(period_start, change[:date])
              folded.balance = [ folded.balance - change[:extra_repayment], BigDecimal("0") ].max
            else
              folded.closing_reduction += change[:extra_repayment]
            end
          end

          if on_payment_date && change[:balance]
            folded.payment_next = change[:payment]
            folded.resize_next = change[:payment].nil?
          elsif change[:payment]
            folded.payment = change[:payment]
            folded.payment_set_on = change[:date]
            folded.resize = false
          else
            folded.payment = nil
            folded.resize = true
          end
        end

        folded
      end

      def term_changes_in(index)
        period_start = index.zero? ? @accrual_start_date : @payment_schedule[index - 1]
        payment_date = @payment_schedule[index]

        @term_changes.select { |change| change[:date] > period_start && change[:date] <= payment_date }
      end

      def grace_day?(period_start, date)
        days = (date - period_start).to_i
        days.positive? && days <= @payment_grace_days
      end

      # Amounts to the currency's precision. An extra repayment smaller than
      # the currency can express repays nothing, and a change left with no
      # amount is dropped.
      def normalize_term_change(change)
        amounts = %i[extra_repayment balance payment].index_with do |key|
          value = change[key]
          BigDecimal(value.to_s).round(@currency_precision) unless value.nil?
        end
        amounts[:extra_repayment] = nil if amounts[:extra_repayment]&.zero?

        { date: change.fetch(:date), **amounts } if amounts.values.any?
      end

      def monthly_rate(annual_percentage)
        AmortizationMath.monthly_rate(annual_percentage)
      end

      def callable!(value, name)
        raise ArgumentError, "#{name} must respond to #call" unless value.respond_to?(:call)

        value
      end
  end
end
