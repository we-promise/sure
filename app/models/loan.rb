class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    annual_rate = interest_rate / 100.0
    monthly_rate = annual_rate / 12.0

    if monthly_rate.zero?
      payment = account.loan.original_balance.amount / term_months
    else
      payment = (account.loan.original_balance.amount * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
    end

    Money.new(payment.round, account.currency)
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
    def build_amortization_schedule
      return [] unless rate_type == "fixed"
      return [] if term_months.nil? || term_months <= 0 || interest_rate.nil?

      principal = original_balance.amount.to_f
      return [] if principal.zero?

      monthly_rate = (interest_rate.to_f / 100.0) / 12.0
      payment = exact_monthly_payment_dollars(principal, monthly_rate)
      start_date = schedule_start_date
      currency = account.currency

      balance = principal
      rows = []

      (1..term_months).each do |period|
        interest_amount = (balance * monthly_rate).round(2)
        principal_amount = (payment - interest_amount).round(2)

        # Absorb rounding drift in the final period so the balance lands exactly on zero.
        if period == term_months || principal_amount > balance
          principal_amount = balance.round(2)
        end

        payment_amount = (interest_amount + principal_amount).round(2)
        ending_balance = (balance - principal_amount).round(2)
        ending_balance = 0.0 if ending_balance.negative?

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

    def exact_monthly_payment_dollars(principal, monthly_rate)
      if monthly_rate.zero?
        (principal / term_months).round(2)
      else
        factor = (1 + monthly_rate)**term_months
        ((principal * monthly_rate * factor) / (factor - 1)).round(2)
      end
    end

    def schedule_start_date
      account.first_valuation&.date || account.created_at&.to_date || Date.current
    end
end
