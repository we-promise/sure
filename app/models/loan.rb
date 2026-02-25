class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

<<<<<<< HEAD
  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
=======
  validates :interest_rate,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true

  validates :term_months,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true

  validates :rate_type,
            inclusion: { in: %w[fixed variable adjustable] },
            allow_nil: true

  validates :down_payment,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true
>>>>>>> 67061b6a (add validates for every fields)

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
end
