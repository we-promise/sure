class Loan
  # Calculates amortization schedules for loans using the constant-payment method
  class AmortizationSchedule
    ALGORITHM_VERSION = 2

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
    def variable_rate?
      loan.rate_type == "variable"
    end

    # Check if the loan has any recorded rate changes to apply mid-schedule
    def has_rate_changes?
      variable_rate? && loan.variable_rate_schedule.present?
    end

    # Get the complete payment schedule as an array of hashes
    def payments
      return [] unless amortizable?
      @schedule_cache ||= generate_schedule
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

      # Generate the complete amortization schedule using the constant-payment method
      # For variable-rate loans, applies rate changes on their effective dates
      def generate_schedule
        schedule = []
        balance = loan.original_balance.amount
        payment_dates = scheduled_payment_dates

        # Build segments from actual payment dates. A rate change between two
        # payments affects the next payment, but does not create a synthetic
        # payment period of its own.
        segments = build_rate_segments(payment_dates)

        payment_num = 1
        segments.each do |segment|
          # Amortize over the payments remaining through loan maturity, not just
          # this segment's own length -- otherwise a segment before the last one
          # gets treated as if the loan ended when the rate changes again, which
          # produces a payment far larger than the correct level payment.
          remaining_payments = loan.term_months - payment_num + 1
          segment_payment = calculate_segment_payment(segment, balance, remaining_payments)

          segment[:payment_count].times do
            break if balance <= 0

            # Use the rate already computed for this segment
            monthly_rate = (segment[:rate] / BigDecimal("100")) / BigDecimal("12")

            interest = (balance * monthly_rate).round(currency_precision)
            principal = segment_payment - interest

            # On final payment, adjust principal to exactly clear the balance
            if payment_num == loan.term_months
              principal = balance
            end

            ending_balance = (balance - principal).round(currency_precision)
            ending_balance = BigDecimal(0) if ending_balance < 0

            # Recalculate payment_amount on final payment to match principal + interest after rounding
            payment_amount = if payment_num == loan.term_months
              (principal + interest).round(currency_precision)
            else
              segment_payment.round(currency_precision)
            end

            schedule << {
              payment_number: payment_num,
              payment_date: payment_dates[payment_num - 1],
              payment_amount: payment_amount,
              principal_payment: principal.round(currency_precision),
              interest_payment: interest.round(currency_precision),
              beginning_balance: balance.round(currency_precision),
              ending_balance: ending_balance,
              interest_rate: segment[:rate]
            }

            balance = ending_balance
            payment_num += 1

            break if balance <= 0
          end
        end

        schedule
      end

      # Get the interest rate effective at a given date
      def get_rate_at_date(date)
        return loan.interest_rate unless variable_rate?

        loan.current_variable_rate(date) || loan.interest_rate
      end

      # Build consecutive segments from the exact dates on which payments are
      # scheduled. Rate changes are effective on the first payment date on or
      # after the change date.
      def build_rate_segments(payment_dates)
        segments = []

        payment_dates.each do |payment_date|
          rate = get_rate_at_date(payment_date)
          if segments.last && segments.last[:rate] == rate
            segments.last[:payment_count] += 1
          else
            segments << {
              rate: rate,
              start_date: payment_date,
              end_date: nil,
              payment_count: 1
            }
          end
        end

        segments
      end

      def first_payment_date
        scheduled_payment_dates.first
      end

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
      def calculate_segment_payment(segment, balance, remaining_payments)
        return BigDecimal("0") if remaining_payments <= 0 || balance <= 0

        monthly_rate = (segment[:rate] / BigDecimal("100")) / BigDecimal("12")

        if monthly_rate.zero?
          (balance / remaining_payments).round(currency_precision)
        else
          numerator = balance * monthly_rate * ((1 + monthly_rate) ** remaining_payments)
          denominator = ((1 + monthly_rate) ** remaining_payments) - 1
          (numerator / denominator).round(currency_precision)
        end
      end

      # Get the currency's decimal precision for rounding
      def currency_precision
        Money::Currency.new(currency).default_precision
      end
  end
end
