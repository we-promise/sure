class Loan
  # Calculates amortization schedules for loans using the constant-payment method
  class AmortizationSchedule
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

    # Get the monthly payment amount (initial payment for variable-rate loans)
    def monthly_payment
      return nil unless amortizable?

      principal = loan.original_balance.amount
      start_date = loan.start_date || loan.account.opening_anchor_date

      # For variable-rate loans, use the initial rate
      rate = if variable_rate?
        loan.current_variable_rate(start_date)
      else
        loan.interest_rate
      end

      annual_rate = rate / 100.0
      monthly_rate = annual_rate / 12.0

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
        current_date = (loan.start_date || loan.account.opening_anchor_date).next_month
        rate_changes = variable_rate? ? loan.variable_rates : []

        # Build segments of payments grouped by interest rate
        segments = build_rate_segments(current_date, rate_changes)

        payment_num = 1
        segments.each do |segment|
          segment_payment = calculate_segment_payment(segment, balance)

          segment[:payment_count].times do
            break if balance <= 0

            # Use the rate already computed for this segment
            annual_rate = segment[:rate] / 100.0
            monthly_rate = annual_rate / 12.0

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
              payment_date: current_date,
              payment_amount: payment_amount,
              principal_payment: principal.round(currency_precision),
              interest_payment: interest.round(currency_precision),
              beginning_balance: balance.round(currency_precision),
              ending_balance: ending_balance,
              interest_rate: segment[:rate]
            }

            balance = ending_balance
            current_date = current_date.next_month
            payment_num += 1

            break if balance <= 0
          end
        end

        schedule
      end

      # Get the interest rate effective at a given date
      def get_rate_at_date(date)
        if variable_rate?
          loan.current_variable_rate(date) || loan.interest_rate
        else
          loan.interest_rate
        end
      end

      # Build segments of rate periods for variable-rate loans
      def build_rate_segments(start_date, rate_changes)
        return [ { rate: loan.interest_rate, start_date: start_date, end_date: nil, payment_count: loan.term_months } ] unless variable_rate?

        segments = []
        change_dates = rate_changes.map { |date_str, _| Date.parse(date_str) }.sort
        current = start_date

        change_dates.each do |change_date|
          if change_date > current
            payment_count = 0
            temp_date = current
            while temp_date < change_date
              payment_count += 1
              temp_date = temp_date.next_month
            end
            segments << {
              rate: get_rate_at_date(current),
              start_date: current,
              end_date: change_date,
              payment_count: payment_count
            }
            current = change_date
          end
        end

        # Final segment for remaining payments
        remaining_payments = loan.term_months - segments.sum { |s| s[:payment_count] }
        if remaining_payments > 0
          segments << {
            rate: get_rate_at_date(current),
            start_date: current,
            end_date: nil,
            payment_count: remaining_payments
          }
        end

        segments
      end

      # Calculate the payment amount for a segment with a specific rate
      def calculate_segment_payment(segment, balance)
        # For simplicity, use the rate from the segment
        annual_rate = segment[:rate] / 100.0
        monthly_rate = annual_rate / 12.0
        remaining_payments = segment[:payment_count]

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
