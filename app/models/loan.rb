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

    amortization_schedule&.periodic_payment
  end

  # A loan can be amortized once we know what was borrowed, at what fixed rate,
  # and over how long. Variable-rate loans are excluded: their payment changes
  # with the rate, so a schedule built off today's rate would be fiction.
  def amortizable?
    rate_type == "fixed" &&
      interest_rate.present? &&
      term_months.to_i.positive? &&
      original_balance.amount.positive?
  end

  def amortization_schedule
    @amortization_schedule ||= AmortizationSchedule.for(self)
  end

  # The date the loan was drawn down. Sure records that as the account's first
  # valuation (the opening balance), falling back to the opening anchor.
  def origination_date
    account.first_valuation&.date || account.opening_anchor_date
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
