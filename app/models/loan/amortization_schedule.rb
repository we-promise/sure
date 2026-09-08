class Loan
  # Calculates amortization schedules for loans using the constant-payment method
  class AmortizationSchedule
    # Whether the PERSISTED schedule accrues interest daily.
    #
    # True as of #10: home loans accrue daily on the end-of-day balance and
    # charge monthly, and for an offset loan monthly accrual is not a
    # simplification but a structural inability to express the product -- it
    # cannot see a balance that moves between payment dates.
    #
    # This constant and ALGORITHM_VERSION move together, and the pairing is
    # pinned by a test. The version is baked into
    # `Loan#amortization_schedule_signature`, so changing it restages every
    # persisted schedule; that is correct here (the numbers genuinely change)
    # and was the defect in #36, where the version advanced while the
    # calculation did not. Deploying this REQUIRES the prebuild in
    # docs/loans/release-evidence.md: read paths enqueue rebuilds rather than
    # performing them (#39), so without a controlled prebuild the estate
    # restages itself through the job queue on first view.
    SCHEDULE_DAILY_ACCRUAL = true
    ALGORITHM_VERSION = 3

    attr_reader :loan

    # Initialize with a loan. The loan may not have an account yet (e.g.
    # Loan.create! is commonly called before being attached to an Account via
    # `Account.create!(accountable: Loan.create!(...))`), so account-dependent
    # state is resolved lazily rather than eagerly in the constructor.
    def initialize(loan)
      @loan = loan
      @schedule_cache = nil
    end

    # The loan's currency, read from its account. Only accessed once
    # #amortizable? has confirmed an account is actually present.
    def currency
      @currency ||= loan.account.currency
    end

    # Check if this loan can be amortized (has an account, positive
    # principal, term, a valid rate type, and a known interest rate).
    # Variable-rate loans are amortizable as soon as a base interest_rate is
    # set -- an explicit variable_rate_schedule is optional and only
    # overrides specific periods.
    def amortizable?
      loan.account.present? &&
        loan.original_balance.positive? &&
        loan.term_months.present? && loan.term_months.positive? &&
        loan.interest_rate.present? &&
        (fixed_rate? || variable_rate?)
    end

    # Check if the loan has a fixed interest rate
    def fixed_rate?
      loan.rate_type == "fixed"
    end

    # Check if the loan has a variable interest rate. A variable-rate loan
    # doesn't need a configured variable_rate_schedule to be amortizable --
    # it simply amortizes at the flat interest_rate until a rate change is
    # recorded.
    #
    # Covers every rate type that can move (Loan::VARIABLE_RATE_TYPES), which
    # includes `adjustable`: before #14 it fell through both branches here and
    # the loan silently had no schedule at all.
    def variable_rate?
      loan.variable_rate_type?
    end

    # Check if the loan has any recorded rate changes to apply mid-schedule
    def has_rate_changes?
      variable_rate? && loan.variable_rate_schedule.present?
    end

    # Get the complete payment schedule as an array of hashes
    def payments
      return [] unless amortizable?
      @schedule_cache ||= generate_simulation(daily_accrual: SCHEDULE_DAILY_ACCRUAL).payments
    end

    # Run an uncached simulation for release comparisons and projections.
    #
    # `daily_accrual:` defaults to the value the persisted schedule uses, so a
    # caller that passes nothing gets the same numbers `#payments` produces.
    # Passing an explicit value is a comparison tool -- `loans:amortization_variance`
    # is its only caller, and it passes BOTH modes explicitly rather than
    # relying on this default, so it keeps measuring monthly-vs-daily whatever
    # SCHEDULE_DAILY_ACCRUAL happens to be.
    def simulation(daily_accrual: SCHEDULE_DAILY_ACCRUAL)
      return Loan::SimulationResult.new(
        payments: [],
        converged: true,
        balloon_amount: BigDecimal("0"),
        currency_precision: currency_precision
      ) unless amortizable?

      generate_simulation(daily_accrual: daily_accrual)
    end

    # Get the total number of payments in the schedule
    def payment_count
      payments.length
    end

    # Get the total interest paid over the life of the loan
    def total_interest
      return Money.new(0, currency) if payments.empty?
      Money.new(payments.sum { |p| p[:interest_payment] }, currency)
    end

    # Get the total cost of the loan (principal + interest)
    def total_cost
      loan.original_balance + total_interest
    end

    # Get the date the loan will be fully paid off
    def payoff_date
      return nil if payments.empty?
      payments.last[:payment_date]
    end

    # Get the payment amount for the first scheduled payment. For variable-rate
    # loans this uses the rate effective on that payment date, so the summary
    # cannot disagree with the first persisted payment row.
    def monthly_payment
      return nil unless amortizable?

      principal = loan.original_balance.amount
      rate = get_rate_at_date(first_payment_date)

      monthly_rate = (rate / BigDecimal("100")) / BigDecimal("12")

      if monthly_rate.zero?
        payment = (principal / loan.term_months).round(currency_precision)
      else
        numerator = principal * monthly_rate * ((1 + monthly_rate) ** loan.term_months)
        denominator = ((1 + monthly_rate) ** loan.term_months) - 1
        payment = (numerator / denominator).round(currency_precision)
      end

      Money.new(payment, currency)
    end

    # True when the persisted rows do not match the loan's current inputs.
    def stale?
      amortizable? && !loan.schedule_current?
    end

    # Rows for the schedule table, as LoanAmortization instances.
    #
    # When the persisted rows are current they ARE the display rows -- the
    # cheap path, and the reason they are persisted at all.
    #
    # When they are stale, return UNSAVED instances computed from the same
    # simulation the summary cards already use. The cards
    # (#monthly_payment, #total_interest, #total_cost, #payoff_date) all
    # compute in memory, so pairing them with stale persisted rows would put
    # two different loans' numbers on one screen -- the inconsistent-figures
    # outcome the design exists to prevent (risk R21).
    #
    # Nothing here writes. Regenerating the persisted rows is the background
    # job's business, not a page view's (#39).
    def display_rows
      return [] unless amortizable?
      return loan.amortizations.ordered.to_a unless stale?

      payments.map do |row|
        LoanAmortization.new(
          loan_id: loan.id,
          payment_number: row[:payment_number],
          payment_date: row[:payment_date],
          payment_amount: row[:payment_amount],
          principal_payment: row[:principal_payment],
          interest_payment: row[:interest_payment],
          beginning_balance: row[:beginning_balance],
          ending_balance: row[:ending_balance],
          interest_rate: row[:interest_rate]
        )
      end
    end

    # FR-205: which displayed payments open a period carrying a new ACCRUAL
    # rate, keyed by payment number and valued by the rate that period ends on.
    #
    # Derived from the accrual clock (C7), NOT by comparing consecutive rows'
    # `interest_rate` -- that column is the PAYMENT-sizing clock (C8), and the
    # two deliberately do not coincide:
    #
    # - a change effective ON a payment date sizes THAT payment, but accrual
    #   windows are half-open, so it belongs to the FOLLOWING window; comparing
    #   payment rates marks the row one payment early;
    # - a change that moves and reverts inside a single payment interval never
    #   shows up in either neighbouring payment's rate at all, so comparing
    #   payment rates marks nothing where the borrower was in fact charged a
    #   different rate for part of the period.
    #
    # The first row is included: its window opens at the accrual start date,
    # which is where Simulator#run opens it too.
    def accrual_rate_change_markers(rows = display_rows)
      return {} unless loan.variable_rate_type?
      return {} if rows.empty?

      # One resolver call over the whole span, then bucketed by walking the two
      # already-sorted lists together. Asking the resolver per row is the
      # obvious shape and was the first one written, but it re-parses and
      # re-sorts every rate change once per payment: 190 ms on a 360-row
      # schedule with 30 changes, on a page render, for a marker.
      changes = RateResolver.for(loan).accrual_rate_changes(
        loan.start_date || loan.account_opening_anchor_date,
        rows.last.payment_date
      )
      return {} if changes.empty?

      next_change = 0

      rows.each_with_object({}) do |row, markers|
        latest = nil

        # Accrual windows are half-open and contiguous, so a change not yet
        # consumed and falling before this row's payment date falls in this
        # row's window. The LAST such change is the rate the window ends on.
        while next_change < changes.length && changes[next_change].fetch(:date) < row.payment_date
          latest = changes[next_change]
          next_change += 1
        end

        markers[row.payment_number] = latest.fetch(:rate) if latest
      end
    end

    # Payments still to come as of `as_of`, counted against the CONTRACTED
    # schedule -- the payments remaining to the original maturity, not a fresh
    # term. Public because #15's current minimum repayment re-amortises over
    # exactly this count, and deriving it separately is how two surfaces end up
    # quoting different figures for one loan.
    # `including_on_date` decides which side of the boundary a payment falling
    # exactly on `as_of` sits. Both callers need a different answer, and the
    # answer must match the balance each is spreading:
    #
    # - today's repayment (default, exclusive): a payment due today has been
    #   made and is already reflected in the balance, so it is not one of the
    #   payments left to spread that balance over;
    # - a future rate change (inclusive): the balance used is that payment's
    #   OPENING balance, so that payment is still to come and must be counted.
    #
    # Getting this wrong is silent -- it moves the quote by one period, which
    # looks like a plausible number.
    def remaining_payment_count(as_of: Date.current, including_on_date: false)
      return 0 unless amortizable?

      scheduled_payment_dates.count do |date|
        including_on_date ? date >= as_of : date > as_of
      end
    end

    # Get a specific payment by date, or nil if not found
    def payment_for(date)
      payment = payments.find { |p| p[:payment_date] == date }
      return nil if payment.nil?

      {
        payment_number: payment[:payment_number],
        payment_date: payment[:payment_date],
        payment_amount: Money.new(payment[:payment_amount], currency),
        principal_payment: Money.new(payment[:principal_payment], currency),
        interest_payment: Money.new(payment[:interest_payment], currency),
        beginning_balance: Money.new(payment[:beginning_balance], currency),
        ending_balance: Money.new(payment[:ending_balance], currency),
        interest_rate: payment[:interest_rate]
      }
    end

    private

      # Configure and run the simulator. This is the ONLY place the production
      # calculation is constructed, so `#payments` and `#simulation` cannot
      # drift apart, and the accrual mode is a required argument rather than an
      # omitted keyword defaulting silently.
      def generate_simulation(daily_accrual:)
        payment_dates = scheduled_payment_dates
        rate_resolver = RateResolver.for(loan)

        Simulator.new(
          starting_balance: loan.original_balance.amount,
          starting_balance_as_of: loan.start_date || loan.account_opening_anchor_date,
          accrual_start_date: loan.start_date || loan.account_opening_anchor_date,
          payment_schedule: payment_dates,
          accrual_rate_for: rate_resolver.method(:accrual_rate_for),
          accrual_rate_changes: rate_resolver.method(:accrual_rate_changes),
          re_amortisation_events: rate_resolver.method(:re_amortisation_events),
          payment_strategy: :reamortize,
          payment_amount_for: ->(rate:, balance:, remaining_payments:, **_kwargs) {
            calculate_segment_payment(rate, balance, remaining_payments)
          },
          currency_precision: currency_precision,
          daily_accrual: daily_accrual,
          day_count_convention: loan.day_count_convention
        ).run
      end

      # Get the interest rate effective at a given date
      def get_rate_at_date(date)
        RateResolver.for(loan).accrual_rate_for(date)
      end

      def first_payment_date
        scheduled_payment_dates.first
      end

      # `Loan#start_date` (falling back to the account's opening-anchor
      # valuation date when unset) is the loan's ORIGINATION/anchor date --
      # e.g. the closing date on a mortgage -- not the first payment date.
      # The first payment falls one calendar month after it, and every
      # subsequent payment one month after that, regardless of which
      # day-of-month the anchor falls on (`Date#next_month` clamps to the
      # shorter month where needed, e.g. Jan 31 -> Feb 28/29 -> Mar 28/29,
      # not Mar 31 -- see `Date#next_month` boundary tests in
      # test/models/loan/amortization_schedule_test.rb).
      def scheduled_payment_dates
        @scheduled_payment_dates ||= begin
          date = loan.start_date || loan.account_opening_anchor_date
          Array.new(loan.term_months) do
            date = date.next_month
          end
        end
      end

      # Calculate the payment amount for a segment with a specific rate,
      # amortized over remaining_payments -- the payments left through loan
      # maturity, not just this segment's own length.
      def calculate_segment_payment(rate, balance, remaining_payments)
        AmortizationMath.level_payment(
          balance: balance,
          monthly_rate: Loan.monthly_rate(rate),
          remaining_payments: remaining_payments,
          currency_precision: currency_precision
        )
      end

      # Get the currency's decimal precision for rounding
      def currency_precision
        Money::Currency.new(currency).default_precision
      end
  end
end
