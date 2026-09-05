class Loan
  # The month-by-month principal a loan SHOULD carry, derived from its terms.
  #
  # Sure stores a liability's history the same way it stores an asset's: the
  # balance moves only when an entry lands on the loan account
  # (Balance::BaseCalculator#derive_non_cash_balance). A loan repaid by direct
  # debit from a checking account has no entries of its own, so its balance sits
  # frozen between manual valuations and then jumps. The recorded net-worth
  # curve therefore shows a plateau followed by a step, and understates the
  # progress actually made in between.
  #
  # This does NOT rewrite `balances`. It derives what the schedule implies and
  # reports the gap, so the size of the distortion is measurable before anyone
  # decides to touch the calculator that produces it.
  class AmortizationSchedule
    # A schedule that has not cleared after 50 years is a runaway, not a loan.
    MAX_PERIODS = 600

    Point = Data.define(:date, :balance, :interest, :principal)

    Divergence = Data.define(:date, :recorded, :expected, :difference)

    attr_reader :loan

    def initialize(loan)
      @loan = loan
    end

    # nil when the terms cannot support a schedule, never a plausible guess.
    # `reason` says which field is missing so a caller can tell the user.
    def available?
      anchor_balance.present? && anchor_balance.positive? &&
        payment.present? && payment.positive? &&
        loan.interest_rate.present?
    end

    def unavailable_reason
      return nil if available?
      return "No monthly payment is known: a fixed rate needs interest_rate and term_months, any other rate needs the actual payment recorded." if payment.nil? || payment.zero?
      return "No starting principal is known: record the loan's original balance or an opening valuation." if anchor_balance.blank? || !anchor_balance.positive?

      # An unknown rate is not a zero rate. Reading it as zero builds an
      # interest-free schedule that clears the loan early and reports no
      # interest at all, which is a confident wrong answer. A declared 0% is a
      # real rate and still produces a schedule.
      "No interest rate is recorded: enter the loan's nominal interest rate (0 is a valid value)."
    end

    # Anchored at origination when the user recorded one, which is what makes a
    # BACKWARD comparison possible. Without it the schedule can only run forward
    # from today, which says nothing about the plateau in the recorded history.
    def anchored_at_origination?
      loan.origination_date.present? && loan.original_balance&.amount.to_d.positive?
    end

    def start_date
      anchored_at_origination? ? loan.origination_date : Date.current
    end

    def points
      @points ||= build_points
    end

    def balance_on(date)
      return nil if points.empty?
      return points.first.balance if date <= points.first.date

      point = points.reverse.find { |candidate| candidate.date <= date }
      point&.balance || 0.to_d
    end

    def payoff_date
      cleared = points.find { |point| point.balance.zero? }
      cleared&.date
    end

    def total_interest
      points.sum(&:interest)
    end

    # What the recorded history says against what the terms imply, on the dates
    # the application actually stored. A large, one-directional gap is the
    # plateau made visible.
    def divergences(limit: 24)
      return [] unless anchored_at_origination?

      recorded_balances(limit).map do |balance|
        expected = balance_on(balance.date)
        next if expected.nil?

        Divergence.new(
          date: balance.date,
          recorded: balance.balance.to_d.round(2),
          expected: expected.round(2),
          difference: (balance.balance.to_d - expected).round(2)
        )
      end.compact
    end

    private
      def account
        loan.account
      end

      def payment
        @payment ||= loan.effective_payment&.amount
      end

      def anchor_balance
        @anchor_balance ||= if anchored_at_origination?
          loan.original_balance.amount
        else
          account.balance.to_d
        end
      end

      # Only reached through `build_points`, which refuses to run unless
      # `available?` has already established that a rate was recorded.
      def monthly_rate
        loan.interest_rate.to_d / 100 / 12
      end

      def build_points
        return [] unless available?

        rate = monthly_rate
        balance = anchor_balance
        date = start_date
        points = [ Point.new(date: date, balance: balance.round(2), interest: 0.to_d, principal: 0.to_d) ]

        MAX_PERIODS.times do
          break if balance <= 0

          interest = (balance * rate).round(2)
          principal = payment - interest
          # A payment that cannot cover the interest never clears the loan.
          # Loan#remaining_payments already refuses to answer in that case;
          # stopping here keeps the two consistent instead of emitting a
          # schedule that quietly grows forever.
          break if principal <= 0

          balance = [ balance - principal, 0.to_d ].max
          date = date.advance(months: 1)

          points << Point.new(date: date, balance: balance.round(2), interest: interest, principal: principal.round(2))
        end

        points
      end

      # Month ends only: a daily series over a 20-year mortgage is thousands of
      # rows nobody reads, and the distortion this exists to expose is measured
      # in months.
      def recorded_balances(limit)
        account.balances
               .where(currency: account.currency)
               .where("date >= ?", start_date)
               .order(date: :desc)
               .limit(limit * 31)
               .to_a
               .group_by { |balance| balance.date.beginning_of_month }
               .values
               .map { |group| group.max_by(&:date) }
               .sort_by(&:date)
               .last(limit)
      end
  end
end
