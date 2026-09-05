class Loan
  # Calculates amortization schedules for loans using the constant-payment method
  class AmortizationSchedule
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
        payment_dates = scheduled_payment_dates
        rate_resolver = RateResolver.for(loan)

        Simulator.new(
          starting_balance: loan.original_balance.amount,
          starting_balance_as_of: loan.start_date || loan.account_opening_anchor_date,
          accrual_start_date: loan.start_date || loan.account_opening_anchor_date,
          payment_schedule: payment_dates,
          accrual_rate_for: rate_resolver.method(:accrual_rate_for),
          re_amortisation_events: rate_resolver.method(:re_amortisation_events),
          payment_strategy: :reamortize,
          payment_amount_for: ->(rate:, balance:, remaining_payments:, **_kwargs) {
            calculate_segment_payment(rate, balance, remaining_payments)
          },
          currency_precision: currency_precision
        ).run.payments
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
        return BigDecimal("0") if remaining_payments <= 0 || balance <= 0

        monthly_rate = (rate / BigDecimal("100")) / BigDecimal("12")

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
