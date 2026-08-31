class Loan
  class AmortizationSchedule
    attr_reader :loan, :currency

    def initialize(loan)
      @loan = loan
      @currency = loan.account.currency
      @schedule_cache = nil
    end

    def amortizable?
      fixed_rate? && loan.original_balance.positive? && loan.term_months.positive?
    end

    def fixed_rate?
      loan.rate_type == "fixed"
    end

    def payments
      return [] unless amortizable?
      @schedule_cache ||= generate_schedule
    end

    def payment_count
      payments.length
    end

    def total_interest
      return Money.new(0, currency) if payments.empty?
      Money.new(payments.sum { |p| p[:interest_payment] }, currency)
    end

    def total_cost
      loan.original_balance + total_interest
    end

    def payoff_date
      return nil if payments.empty?
      payments.last[:payment_date]
    end

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

        # On final payment, adjust for rounding
        if payment_num == loan.term_months
          principal = balance
        end

        ending_balance = (balance - principal).round(currency_precision)
        ending_balance = BigDecimal(0) if ending_balance < 0

        schedule << {
          payment_number: payment_num,
          payment_date: current_date,
          payment_amount: payment.round(currency_precision),
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

    def currency_precision
      Money::Currency.new(currency).default_precision
    end
  end
end
