class Loan
  # Projects a loan's payoff from its *current actual balance* rather than
  # its original contracted balance -- so a user who has made extra
  # principal payments sees a sooner payoff date and the interest they
  # saved, instead of the static original-terms schedule from
  # AmortizationSchedule.
  #
  # Deliberately keeps the ORIGINAL schedule's monthly payment amount fixed
  # and simulates forward from today's balance, rather than re-amortizing
  # the remaining term at the current balance. Re-amortizing would *lower*
  # the payment to fit the remaining term; what we want is "same payment,
  # paid off sooner" -- the real-world effect of an extra/lump-sum payment.
  #
  # Not persisted: computed live from loan.account.balance on every call, so
  # it's automatically current after every sync or manual balance update.
  #
  # Caveat: treats account.balance as principal-only (same assumption
  # AmortizationSchedule makes about original_balance). A provider-synced
  # balance that includes escrow will understate interest/time saved.
  class PayoffProjection
    MAX_ITERATIONS_MULTIPLIER = 2
    EXTRA_PAYMENT_FREQUENCIES = %w[weekly monthly yearly].freeze

    attr_reader :loan, :extra_payment

    # extra_payment: an optional hypothetical monthly-equivalent Money
    # amount added on top of the original schedule's payment -- used to
    # model "what if I also paid an extra $X/week|month|year" without
    # touching the account's real balance or the persisted schedule. See
    # .monthly_equivalent for how a user-entered amount + cadence becomes
    # this value.
    # `repayment_plan:` carries a scenario's extra repayments (#16). It is a
    # separate input from `extra_payment:` on purpose, and they answer
    # different questions:
    #
    #   extra_payment   -- "what if I paid $X MORE every month", modelled by
    #                      raising the recurring repayment amount;
    #   repayment_plan  -- dated lump sums and cadences that reduce the balance
    #                      on their own effective dates (C6), leaving the
    #                      contracted repayment where it is.
    #
    # Collapsing the second into a monthly equivalent of the first is exactly
    # what C6 forbids: it would charge interest the borrower did not owe
    # between the real repayment date and the notional month end.
    def initialize(loan, extra_payment: nil, scenario: nil)
      @loan = loan
      @extra_payment = extra_payment
      @scenario = scenario
      # No rebuild is enqueued here. The version of this on #4 did so from the
      # constructor, which makes merely instantiating a projection a
      # side-effecting act. Since #39 the read paths own that: the Schedule tab
      # and Api::V1::LoansController both enqueue LoanAmortizationRebuildJob
      # when the persisted rows are not current.
    end

    # Converts a user-entered amount + cadence into the monthly-equivalent
    # Money this class models payments in. This is an approximation --
    # weekly extra payments really do compound faster than a monthly lump
    # sum, because they reduce principal between the monthly accrual points
    # this simulation (and the rest of the amortization feature) uses -- but
    # no part of this codebase models daily/weekly accrual, so a monthly
    # equivalent is consistent with the existing granularity rather than a
    # new gap. Returns nil for a blank/zero/invalid amount; raises on an
    # unrecognized frequency (callers are expected to validate frequency at
    # the request boundary, not rely on this method to sanitize it).
    def self.monthly_equivalent(amount:, frequency:, currency:)
      unless EXTRA_PAYMENT_FREQUENCIES.include?(frequency.to_s)
        raise ArgumentError, "unsupported frequency: #{frequency.inspect}"
      end

      return nil if amount.blank?

      parsed = begin
        BigDecimal(amount.to_s)
      rescue ArgumentError, TypeError
        nil
      end
      # finite? first: BigDecimal("NaN") and BigDecimal("Infinity") both survive
      # `parsed <= 0` -- NaN because every comparison against it is false, and
      # Infinity because it is genuinely positive. Money.new accepts either, so
      # a non-finite extra payment would reach Loan::Simulator and poison the
      # projection. The controller already rejects these at the request
      # boundary; this is the same check where the value is actually converted,
      # for callers that do not come through it.
      return nil if parsed.nil? || !parsed.finite? || parsed <= 0

      monthly_amount = case frequency.to_s
      when "weekly" then parsed * 52 / 12
      when "yearly" then parsed / 12
      else parsed
      end

      Money.new(monthly_amount, currency)
    end

    # Coarser eligibility than #applicable? -- true whenever a hypothetical
    # extra payment *could* make this loan's projection applicable, even if
    # the baseline (no-extra) payment currently doesn't cover interest or
    # converge. Used to decide whether to show the what-if input at all: a
    # loan whose current payment barely covers interest is exactly the case
    # where a user most wants to model paying more, so the input shouldn't
    # be hidden based on the unboosted result.
    # Deliberately does NOT require fixed_rate?.
    #
    # It used to, which made this disagree with #applicable? after #12 removed
    # the same gate there: a variable-rate loan would show a projection and a
    # payoff chart but no way to model paying extra -- and a variable-rate
    # borrower is arguably the one who most wants to, because their contracted
    # payment moves under them (#54).
    #
    # The what-if holds the payment flat while simulating forward. For a
    # variable loan that compounds two hypotheticals, so the UI discloses the
    # assumption rather than the control being withheld.
    def self.eligible_for_extra_payment?(loan)
      loan.amortization_schedule.amortizable? &&
        loan.account.present? &&
        loan.account.balance.present? &&
        loan.account.balance.positive?
    end

    def currency
      @currency ||= loan.account.currency
    end

    # Loans with a real payment amount and a positive
    # current balance are eligible -- and only when there's actually
    # something to project (the original schedule must be amortizable) AND
    # the simulation actually converges to zero within the iteration cap
    # (see #converged? -- a payment that technically covers interest but
    # would take an implausibly long time is treated as not applicable
    # rather than silently reporting a truncated, non-payoff "payoff date").
    def applicable?
      loan.amortization_schedule.amortizable? &&
        original_schedule_rows.any? &&
        monthly_payment.present? && monthly_payment.amount.positive? &&
        current_balance.amount.positive? &&
        !unamortizable_payment? &&
        converged?
    end

    def current_balance
      Money.new(loan.account.balance, currency)
    end

    # The payment this projection actually models -- the original
    # schedule's payment, plus the hypothetical extra when one is present.
    def monthly_payment
      base = loan.amortization_schedule.monthly_payment
      return base if extra_payment.blank? || extra_payment.amount.zero?
      base + extra_payment
    end

    # The simulated forward schedule from today until the balance is paid off.
    def payments
      return [] unless applicable?
      raw_schedule
    end

    def payment_count
      payments.length
    end

    # Reports whether the raw simulation reaches an exact zero balance within
    # its bounded horizon, independently of whether the result is displayable.
    def converged?
      schedule = raw_schedule
      schedule.present? && schedule.last[:ending_balance].zero?
    end

    def payoff_date
      return nil if payments.empty?
      payments.last[:payment_date]
    end

    def total_interest
      return Money.new(0, currency) if payments.empty?
      Money.new(payments.sum { |p| p[:interest_payment] }, currency)
    end

    # How many fewer payments this projection takes versus the original
    # schedule's remaining payments as of today. Positive means ahead of
    # schedule (paid off sooner); negative means behind.
    def months_saved
      return nil unless applicable?
      original_remaining_payment_count - payment_count
    end

    # Whether this projection differs from the contracted schedule by enough
    # to be worth showing the user.
    #
    # The two simulations terminate independently. The contracted schedule
    # knows its final period in advance and resizes that payment to clear the
    # balance exactly (C14); this projection keeps paying the level payment
    # and only adjusts once a payment would overshoot. So a loan sitting
    # exactly on its contract can still trail by one small "cleanup" payment
    # -- a real artefact of two independently-terminated runs, not a real
    # divergence, and one this class has always tolerated.
    #
    # That artefact used to be bounded by a hardcoded $1, which fitted the
    # monthly-accrual residue and nothing else: under daily accrual the same
    # untouched loan trails by $1.10 and every chart would have claimed the
    # borrower was behind schedule. The bound here is the artefact itself --
    # the trailing payment's own interest -- so it holds for any accrual
    # model rather than for the one it was measured against.
    def diverges_from_schedule?
      return false unless applicable?
      return true if months_saved.abs > 1
      return false if cleanup_payment_artefact?

      interest_saved.abs >= 1
    end

    # True when the whole interest difference is accounted for by a single
    # trailing cleanup payment, i.e. the projection ran exactly one payment
    # longer and paid no more interest than that payment itself charged.
    def cleanup_payment_artefact?
      return false unless months_saved == -1

      interest_saved.abs <= payments.last[:interest_payment]
    end

    # How much less interest this projection pays versus the original
    # schedule's remaining interest as of today. Positive means savings;
    # negative means more interest will be paid (behind schedule).
    # Both sides of the comparison come from the same accrual model as the
    # persisted schedule (see `generate_schedule`), so this figure is a
    # like-for-like difference rather than an artefact of two calculations.
    def interest_saved
      return nil unless applicable?
      (original_remaining_interest - total_interest.amount)
    end

    private

      def unamortizable_payment?
        rate = Loan::RateResolver.for(loan).accrual_rate_for(first_projected_payment_date)
        monthly_rate = (BigDecimal(rate.to_s) / BigDecimal("100")) / BigDecimal("12")
        return false if monthly_rate.zero?

        first_interest = current_balance.amount * monthly_rate
        monthly_payment.amount <= first_interest
      end

      # The contracted schedule this projection is compared against.
      #
      # Read through AmortizationSchedule#display_rows rather than
      # loan.amortizations directly, so the projection uses the same rows the
      # table and the summary cards show. The persisted rows are used when they
      # are current; when they are stale the schedule recomputes them in memory.
      #
      # This used to read loan.amortizations and required rows to exist, which
      # silently disabled the projection whenever the persisted schedule was
      # missing -- previously masked because the Schedule tab rebuilt it inside
      # the request. It no longer does (#39), so a display calculation must not
      # depend on a write having happened.
      def original_schedule_rows
        @original_schedule_rows ||= loan.amortization_schedule.display_rows
      end

      # Nil rather than an empty lambda when there is no scenario, so the
      # simulator keeps its own default and a baseline projection is
      # byte-identical to what it was before scenarios existed.
      #
      # `closes_on` is the projection's own last payment date: the plan's
      # windows are half-open to avoid double-applying a repayment that lands on
      # a payment date, which leaves the final date in no window at all unless
      # the last one is told to close inclusively.
      def extra_repayment_resolver
        return nil if @scenario.nil?

        Loan::RepaymentPlan.for(@scenario, closes_on: projected_payment_dates.last)
          .method(:change_points)
      end

      def original_remaining_payments
        @original_remaining_payments ||= original_schedule_rows.select do |row|
          row.payment_date > Date.current
        end
      end

      def first_projected_payment_date
        original_remaining_payments.first&.payment_date || Date.current.next_month
      end

      def original_remaining_payment_count
        original_remaining_payments.count
      end

      def original_remaining_interest
        original_remaining_payments.sum(BigDecimal("0")) { |row| row.interest_payment }
      end

      # The raw simulation, independent of #applicable? (which itself needs
      # to inspect this to determine convergence -- see #converged?).
      # Memoized: safe to call repeatedly within one instance's lifetime.
      def raw_schedule
        @raw_schedule ||= generate_schedule
      end

      def generate_schedule
        payment_dates = projected_payment_dates
        rate_resolver = Loan::RateResolver.for(loan)

        Loan::Simulator.new(
          starting_balance: current_balance.amount,
          starting_balance_as_of: Date.current,
          accrual_start_date: Date.current,
          payment_schedule: payment_dates,
          accrual_rate_for: rate_resolver.method(:accrual_rate_for),
          # The ACCRUAL clock's change points, which segment a daily accrual
          # window (C7/C10). Omitting this defaulted the simulator to "no rate
          # changes", so a rate effective between two payment dates moved the
          # persisted schedule's interest but not this projection's -- the same
          # phantom divergence as running two accrual models, arriving instead
          # through one model missing half its inputs. It only bites on the
          # daily branch, which is why it was invisible while the projection
          # ran daily solely for offset loans.
          accrual_rate_changes: rate_resolver.method(:accrual_rate_changes),
          re_amortisation_events: rate_resolver.method(:re_amortisation_events),
          payment_strategy: :hold,
          payment_amount_for: ->(**_kwargs) { monthly_payment.amount },
          currency_precision: currency_precision,
          max_iterations: payment_dates.length,
          settle_at_schedule_end: false,
          # Follow the persisted schedule's accrual mode. The projection is
          # compared against that schedule row-for-row (see
          # `original_remaining_interest` and `months_saved`), so if the two
          # run different accrual models an untouched loan reads as diverging
          # from its own contract -- a phantom "ahead of schedule" on every
          # chart. Offset loans stay on daily regardless, since a daily
          # offset balance has no monthly equivalent; a zero-balance link is
          # mathematically the no-offset case and is kept off the offset
          # branch so linking an empty asset does not change figures merely
          # by changing the calculation mode.
          daily_accrual: Loan::AmortizationSchedule::SCHEDULE_DAILY_ACCRUAL ||
            (loan.offset_accounts.any? && loan.offset_accounts.sum(:balance).positive?),
          day_count_convention: loan.day_count_convention,
          offset_for: Loan::OffsetResolver.new(loan).method(:change_points),
          extra_for: extra_repayment_resolver
        ).run.payments
      end

      def projected_payment_dates
        first_date = first_projected_payment_date
        max_iterations = MAX_ITERATIONS_MULTIPLIER * loan.term_months
        Array.new(max_iterations) do |index|
          first_date >> index
        end
      end

      def currency_precision
        Money::Currency.new(currency).default_precision
      end
  end
end
