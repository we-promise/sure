class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if original_balance.amount.zero? || term_months.zero?

    Money.new(exact_monthly_payment(original_balance.amount, monthly_rate).round(2), account.currency)
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  # Returns a French-style amortization schedule as an array of period hashes:
  # { period:, payment_date:, beginning_balance:, payment:, interest:, principal:, ending_balance: }
  # Returns [] when the loan does not have enough parameters to project a fixed-rate schedule.
  def amortization_schedule
    return @amortization_schedule if defined?(@amortization_schedule)

    @amortization_schedule = build_amortization_schedule
  end

  def total_interest
    schedule = amortization_schedule
    return nil if schedule.empty?

    Money.new(schedule.sum { |row| row[:interest].amount }, account.currency)
  end

  def total_payments
    schedule = amortization_schedule
    return nil if schedule.empty?

    Money.new(schedule.sum { |row| row[:payment].amount }, account.currency)
  end

  def payoff_date
    amortization_schedule.last&.dig(:payment_date)
  end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end

  private
    # Schedule arithmetic is done end-to-end in BigDecimal so 360 iterations don't accumulate
    # binary-floating-point drift. The final-period correction still absorbs any sub-cent
    # rounding remainder so the loan zeroes out exactly.
    DIVISION_PRECISION = 18
    ZERO = BigDecimal("0").freeze

    def build_amortization_schedule
      return [] unless rate_type == "fixed"
      return [] if term_months.nil? || term_months <= 0 || interest_rate.nil?

      principal = original_balance.amount
      return [] if principal.zero?

      rate = monthly_rate
      payment = exact_monthly_payment(principal, rate)
      start_date = schedule_start_date
      currency = account.currency

      balance = principal
      rows = []

      (1..term_months).each do |period|
        interest_amount = (balance * rate).round(2)
        principal_amount = (payment - interest_amount).round(2)

        # Absorb rounding drift in the final period so the balance lands exactly on zero.
        if period == term_months || principal_amount > balance
          principal_amount = balance.round(2)
        end

        payment_amount = (interest_amount + principal_amount).round(2)
        ending_balance = (balance - principal_amount).round(2)
        ending_balance = ZERO if ending_balance.negative?

        rows << {
          period: period,
          payment_date: start_date >> period,
          beginning_balance: Money.new(balance.round(2), currency),
          payment: Money.new(payment_amount, currency),
          interest: Money.new(interest_amount, currency),
          principal: Money.new(principal_amount, currency),
          ending_balance: Money.new(ending_balance, currency)
        }

        balance = ending_balance
      end

      rows
    end

    def exact_monthly_payment(principal, monthly_rate)
      if monthly_rate.zero?
        principal.div(term_months, DIVISION_PRECISION)
      else
        factor = (1 + monthly_rate) ** term_months
        principal.mul(monthly_rate, DIVISION_PRECISION)
                 .mul(factor, DIVISION_PRECISION)
                 .div(factor - 1, DIVISION_PRECISION)
      end
    end

    def monthly_rate
      (interest_rate.to_d / 100).div(12, DIVISION_PRECISION)
    end

    def schedule_start_date
      account.first_valuation&.date || account.created_at&.to_date || Date.current
    end
end
