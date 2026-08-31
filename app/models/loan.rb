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

  has_many :amortizations, class_name: "LoanAmortization", dependent: :destroy

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  def monthly_payment
    amortization_schedule.monthly_payment
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  def amortization_schedule
    @amortization_schedule ||= AmortizationSchedule.new(self)
  end

  def amortizable?
    amortization_schedule.amortizable?
  end

  def add_variable_rate_change(date, rate)
    self.variable_rate_schedule ||= {}
    self.variable_rate_schedule[date.to_s] = rate
    self.next_rate_change_date = find_next_rate_change_date
    save
  end

  def variable_rates
    (variable_rate_schedule || {}).sort_by { |date, _| Date.parse(date) }
  end

  def current_variable_rate(as_of_date = Date.current)
    rates = variable_rates.reverse
    rates.find { |date_str, _| Date.parse(date_str) <= as_of_date }&.last || interest_rate
  end

  def rebuild_amortization_schedule
    return unless amortizable?

    transaction do
      amortizations.destroy_all
      amortization_schedule.payments.each do |payment_data|
        amortizations.create!(
          payment_number: payment_data[:payment_number],
          payment_date: payment_data[:payment_date],
          payment_amount: payment_data[:payment_amount],
          principal_payment: payment_data[:principal_payment],
          interest_payment: payment_data[:interest_payment],
          beginning_balance: payment_data[:beginning_balance],
          ending_balance: payment_data[:ending_balance],
          interest_rate: payment_data[:interest_rate]
        )
      end
    end
  end

  private

  def find_next_rate_change_date
    return nil if variable_rate_schedule.blank?
    dates = variable_rate_schedule.keys.map { |d| Date.parse(d) }
    future_dates = dates.select { |d| d > Date.current }
    future_dates.min
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
