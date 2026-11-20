class Loan
  # Where the loan is actually heading, starting from today's real balance
  # rather than from the contract.
  #
  # The contracted schedule answers "what did you agree to?". This answers "what
  # is going to happen?", and the gap between them is the whole point: a
  # borrower who has overpaid is ahead of the schedule, one whose balance has
  # grown is behind, and neither is visible from the contract alone.
  #
  # It pays the repayment the CONTRACT requires in each period -- the
  # schedule's own row, re-amortised wherever the schedule re-amortises --
  # against a balance that is no longer the contracted one. That is deliberate:
  # re-sizing the repayment to today's balance would answer a different and much
  # less useful question, and would land every borrower who is ahead back on
  # the original maturity. Paying what the contract asks against a smaller
  # balance is how they finish sooner.
  #
  # Extra payments the borrower has already made are in here without being
  # named: they are why today's balance is what it is.
  #
  # `extra` is a hypothetical: an amount paid on top of the contract's
  # repayment from here on, for the Extra repayments tab's "what if I pay
  # more?". nil, the default, is the projection above. `extra_frequency` says
  # how often: monthly puts one extra in every repayment period; weekly and
  # fortnightly extras fall on their own dates (see #extra_for).
  class PayoffProjection
    EXTRA_FREQUENCIES = %w[weekly fortnightly monthly].freeze

    # Days between dated extras. Monthly is not dated: it rides on every
    # repayment, as the schedule's own payments do.
    EXTRA_INTERVAL_DAYS = { "weekly" => 7, "fortnightly" => 14 }.freeze

    attr_reader :loan, :as_of, :extra, :extra_frequency

    def initialize(loan, as_of: Date.current, extra: nil, extra_frequency: "monthly")
      raise ArgumentError, "Unknown extra frequency: #{extra_frequency.inspect}" unless EXTRA_FREQUENCIES.include?(extra_frequency)

      @loan = loan
      @as_of = as_of
      @extra = extra.nil? ? nil : BigDecimal(extra.to_s)
      @extra_frequency = extra_frequency
    end

    # False when there is nothing to project: no schedule, nothing left to owe,
    # or no repayment ahead. A payment of zero in the next period, a payment
    # holiday on an interest-free loan, still projects when a later payment
    # repays the loan.
    def applicable?
      schedule.present? &&
        current_balance.amount.positive? &&
        remaining_scheduled_payments.any? { |payment| payment.payment.amount.positive? }
    end

    # True when nothing is owed. Only one of the reasons applicable? can be
    # false: a loan past its last scheduled repayment with a balance still
    # owing is not settled, and the Extra repayments tab says so differently.
    def settled?
      !current_balance.amount.positive?
    end

    def currency
      loan.account.currency
    end

    # `accounts.balance` is nullable, and Money.new(nil) raises. A loan with no
    # balance yet has nothing to project, so it reads as zero: applicable? is
    # then false and the Schedule tab's card says so instead of the page failing.
    def current_balance
      @current_balance ||= Money.new(loan.account.balance || 0, currency)
    end

    def payments
      simulation&.payments || []
    end

    def payoff_date
      simulation&.payoff_date
    end

    def total_interest
      Money.new(simulation&.total_interest || 0, currency)
    end

    # False when the contracted repayment does not clear the balance by the
    # original maturity -- the borrower is far enough behind that the contract
    # no longer pays the loan off. There is no payoff date in that case.
    def converged?
      simulation ? simulation.converged? : false
    end

    def balloon_amount
      Money.new(simulation&.balloon_amount || 0, currency)
    end

    # Positive means the loan finishes earlier than the contract said. Zero for
    # a run that never clears the balance: it walks every remaining date, so
    # there is nothing to subtract -- no convergence guard is needed here, and
    # one would be untestable, which is why it is not.
    def months_saved
      return 0 unless applicable?

      remaining_payment_dates.length - payments.length
    end

    # Positive means less interest than the contract's remaining interest.
    def interest_saved
      return Money.new(0, currency) unless applicable?

      Money.new(remaining_contracted_interest - (simulation&.total_interest || 0), currency)
    end

    # What is still to repay from today: the balance plus the interest of
    # every remaining period, which is what the payments add up to. nil for a
    # run that never clears: a balloon would still be owed on top.
    def total_cost
      return nil unless converged?

      current_balance + total_interest
    end

    # How much less this projection costs from today than `other`, on the same
    # terms as #months_sooner_than. Both repay the same balance, so this is
    # the interest saved, put as the loan's total.
    def total_cost_saved_versus(other)
      return nil unless converged? && other.converged?

      other.total_cost - total_cost
    end

    # How much sooner this projection clears the loan than `other`, a
    # projection of the same loan on the same `as_of`. Both walk the same
    # remaining payment dates, so the difference in rows is the difference in
    # months. nil unless both clear the loan: one that never does has no
    # payoff date to be sooner than.
    def months_sooner_than(other)
      return nil unless converged? && other.converged?

      other.payments.length - payments.length
    end

    # The interest this projection saves against `other`, on the same terms
    # as #months_sooner_than. Measured against another projection, not the
    # contract: #interest_saved already answers that, and folds in how far
    # ahead or behind the loan is today.
    def interest_saved_versus(other)
      return nil unless converged? && other.converged?

      other.total_interest - total_interest
    end

    private
      def schedule
        @schedule ||= loan.amortization_schedule
      end

      # The contract's rows still ahead, in order. The projection walks exactly
      # these dates, so position `index` in its run is position `index` here.
      def remaining_scheduled_payments
        @remaining_scheduled_payments ||= (schedule&.payments || [])
          .select { |payment| payment.date > as_of }
      end

      # The payment dates still ahead. A projection runs to the ORIGINAL
      # maturity and no further: extending it would invent a term the borrower
      # never agreed to.
      def remaining_payment_dates
        @remaining_payment_dates ||= remaining_scheduled_payments.map(&:date)
      end

      # What the contract asks for in the projection's period `index`: the
      # schedule's row for the same date. The two walks share their dates, so a
      # recorded rate change re-sizes this exactly where the schedule re-sizes
      # its own repayment. Past the last row -- unreachable today, since the
      # projection stops at the original maturity -- the last amount holds.
      #
      # Plus the period's extra, when there is one. The simulator settles the
      # final period at whatever the balance needs, so an extra larger than
      # what is left is never overpaid.
      def scheduled_payment_for(index:, **)
        row = remaining_scheduled_payments[index] || remaining_scheduled_payments.last
        row.payment.amount + extra_for(index)
      end

      # The extra paid in period `index`. Monthly: one extra, every period.
      # Weekly and fortnightly: the extras dated inside the period, which runs
      # from the previous payment date (exclusive) to its own (inclusive). The
      # first extra falls the day after as_of, so the first period runs from
      # as_of. The simulator charges interest once a period on the balance it
      # opened with, so an extra paid mid-period starts saving from the next.
      def extra_for(index)
        return 0 unless extra
        return extra unless (interval = EXTRA_INTERVAL_DAYS[extra_frequency])

        opens = index.zero? ? as_of : remaining_payment_dates[index - 1]
        closes = remaining_payment_dates[index]
        return 0 unless closes

        extra * (dated_extras_through(closes, interval) - dated_extras_through(opens, interval))
      end

      # How many dated extras fall on or before `date`: the first is the day
      # after as_of, then one every `interval` days.
      def dated_extras_through(date, interval)
        first = as_of + 1
        date < first ? 0 : ((date - first).to_i / interval) + 1
      end

      # Less the current period's interest an extra repayment already paid
      # (see #current_period_interest), so a borrower on contract saves nothing.
      def remaining_contracted_interest
        contracted = remaining_scheduled_payments.sum(BigDecimal("0")) { |payment| payment.interest.amount }
        return contracted unless balance_change_in_current_period? && transfers_pay_interest_first?

        row = remaining_scheduled_payments.first
        contracted - [ repaid_after_charge(row), row.interest.amount ].min
      end

      # The date the period containing `as_of` opened: the last scheduled
      # payment on or before it, or origination before the first. The simulator
      # charges a period at the rate in force when it OPENED, so the projection's
      # first period opens where the schedule's does. Opened at `as_of`, a rate
      # change recorded between the last payment and today re-rated a month the
      # schedule charges at the old rate, and a borrower exactly on contract was
      # quoted interest they will never pay.
      def current_period_start
        schedule.payments.reverse_each.find { |payment| payment.date <= as_of }&.date || schedule.start_date
      end

      # What the period containing `as_of` still charges, when a term change
      # that moved the balance is dated in that period. Nil otherwise, and the
      # simulator charges a full period on today's balance.
      #
      # The schedule sized that row's payment on its own charge: from the date
      # of a confirmed balance, or on the balance before an extra repayment.
      # A full period on today's balance is a different amount, and against a
      # payment sized to the cent the difference reads as a loan that is not
      # paid off. So the first period charges today's balance the way the
      # schedule's row charged its own.
      #
      # An extra repayment made after the period's charge is no longer in
      # today's balance. Where the ledger replay governs the balance, that
      # transfer paid the period's interest first, so the interest is charged
      # on today's balance and the repayment taken off it. Otherwise the whole
      # transfer came off the balance and the interest is still to pay, so it
      # is charged on the balance before the repayment.
      #
      # One limit: on an insured loan the replay also takes the instalment's
      # premium out of that transfer, so until the payment date today's
      # balance is higher by the premium than this assumes.
      def current_period_interest
        return @current_period_interest if defined?(@current_period_interest)

        row = remaining_scheduled_payments.first
        factor = schedule.interest_factor_for(row) if row && balance_change_in_current_period?

        @current_period_interest =
          if factor.nil?
            nil
          elsif transfers_pay_interest_first?
            [ current_balance.amount * factor - repaid_after_charge(row), BigDecimal("0") ].max.round(currency_precision)
          else
            ((current_balance.amount + repaid_after_charge(row)) * factor).round(currency_precision)
          end
      end

      def repaid_after_charge(row)
        schedule.repaid_after_charge_for(row)&.amount || BigDecimal("0")
      end

      def transfers_pay_interest_first?
        return @transfers_pay_interest_first if defined?(@transfers_pay_interest_first)

        @transfers_pay_interest_first = !loan.principal_only_transfers? && loan.principal_replay_active?
      end

      # A change of the payment alone leaves the period's charge as it was.
      def balance_change_in_current_period?
        return @balance_change_in_current_period if defined?(@balance_change_in_current_period)

        opened = current_period_start
        @balance_change_in_current_period = loan.active_term_changes.any? do |change|
          (change.extra_repayment || change.balance) && change.effective_date > opened && change.effective_date <= as_of
        end
      end

      def simulation
        return nil unless applicable?

        @simulation ||= Simulator.new(
          starting_balance: current_balance.amount,
          accrual_start_date: current_period_start,
          payment_schedule: remaining_payment_dates,
          accrual_rate_for: rate_resolver.method(:accrual_rate_for),
          re_amortisation_events: rate_resolver.method(:re_amortisation_events),
          # The contract's own repayment, period by period. Not :reamortize:
          # that re-sizes off the balance in front of it, and for a borrower
          # who is ahead that shrinks the repayment until the loan lands back
          # on the original maturity -- the opposite of what paying the
          # contracted amount against a smaller balance actually does. On a
          # fixed loan every row carries the same figure, so this is the held
          # contracted payment; on a variable loan it moves exactly where the
          # schedule's does.
          payment_amount: method(:scheduled_payment_for),
          payment_strategy: :scheduled,
          first_period_interest: current_period_interest,
          currency_precision: currency_precision,
          # A projection that cannot clear the balance must SAY so. Settling the
          # final payment regardless would manufacture a payoff date for a loan
          # the contract no longer pays off.
          settle_at_schedule_end: false,
          # Charged on the same basis as the schedule it is compared with. Left
          # to the simulator's default, a loan on actual/365 would be projected
          # on a flat twelfth beside a schedule that is not, and a borrower
          # exactly on contract would be quoted interest saved or lost that
          # only the difference in basis produced.
          day_count_convention: loan.day_count_convention
        ).run
      end

      def rate_resolver
        @rate_resolver ||= RateResolver.for(loan)
      end

      def currency_precision
        @currency_precision ||= Money::Currency.new(currency).default_precision || 2
      end
  end
end
