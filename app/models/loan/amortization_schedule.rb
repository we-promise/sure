class Loan
  # Calculates amortization schedules for loans using the constant-payment method
  class AmortizationSchedule
    attr_reader :loan, :currency

    # Initialize with a loan account
    def initialize(loan)
      @loan = loan
      @currency = loan.account.currency
      @schedule_cache = nil
    end

    # Check if this loan can be amortized (fixed-rate with positive principal and term)
    def amortizable?
      fixed_rate? && loan.original_balance.positive? && loan.term_months.positive?
    end

    # Check if the loan has a fixed interest rate
    def fixed_rate?
      loan.rate_type == "fixed"
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

    # Get the monthly payment amount
    def monthly_payment
      return Money.new(0, currency) unless amortizable?

      principal = loan.original_balance.amount
      annual_rate = loan.interest_rate / 100.0
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
    def generate_schedule
      schedule = []
      balance = loan.original_balance.amount
      payment = monthly_payment.amount
      current_date = (loan.start_date || loan.account.opening_anchor_date).next_month
      annual_rate = loan.interest_rate / 100.0
      monthly_rate = annual_rate / 12.0

      (1..loan.term_months).each do |payment_num|
        interest = (balance * monthly_rate).round(currency_precision)
        principal = payment - interest

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
                          payment.round(currency_precision)
                        end

        schedule << {
          payment_number: payment_num,
          payment_date: current_date,
          payment_amount: payment_amount,
          principal_payment: principal.round(currency_precision),
          interest_payment: interest.round(currency_precision),
          beginning_balance: balance.round(currency_precision),
          ending_balance: ending_balance,
          interest_rate: loan.interest_rate
        }

        balance = ending_balance
        current_date = current_date.next_month

        break if balance <= 0
      end

      schedule
    end

    # Get the currency's decimal precision for rounding
    def currency_precision
      Money::Currency.new(currency).default_precision
    end
  end
end
