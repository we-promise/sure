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
  # balance is how they finish sooner (#100, decision 1).
  #
  # Extra payments the borrower has already made are in here without being
  # named: they are why today's balance is what it is.
  class PayoffProjection
    attr_reader :loan, :as_of

    def initialize(loan, as_of: Date.current)
      @loan = loan
      @as_of = as_of
    end

    # False when there is nothing to project: no schedule, nothing left to owe,
    # no payments remaining, or no repayment to hold.
    def applicable?
      schedule.present? &&
        current_balance.amount.positive? &&
        remaining_payment_dates.any? &&
        contracted_payment&.positive? || false
    end

    def currency
      loan.account.currency
    end

    def current_balance
      @current_balance ||= Money.new(loan.account.balance, currency)
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

      # The repayment in force: the next scheduled payment's amount. For a
      # re-amortising loan that is the figure the current rate produced, which
      # is what the borrower is actually paying.
      def contracted_payment
        @contracted_payment ||= remaining_scheduled_payments.first&.payment&.amount
      end

      # What the contract asks for in the projection's period `index`: the
      # schedule's row for the same date. The two walks share their dates, so a
      # recorded rate change re-sizes this exactly where the schedule re-sizes
      # its own repayment. Past the last row -- unreachable today, since the
      # projection stops at the original maturity -- the last amount holds.
      def scheduled_payment_for(index:, **)
        row = remaining_scheduled_payments[index] || remaining_scheduled_payments.last
        row.payment.amount
      end

      def remaining_contracted_interest
        remaining_scheduled_payments.sum(BigDecimal("0")) { |payment| payment.interest.amount }
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
          currency_precision: currency_precision,
          # A projection that cannot clear the balance must SAY so. Settling the
          # final payment regardless would manufacture a payoff date for a loan
          # the contract no longer pays off.
          settle_at_schedule_end: false
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
