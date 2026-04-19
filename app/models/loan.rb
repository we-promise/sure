class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  before_validation :set_default_start_date, on: :create

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  validates :interest_rate,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true

  validates :insurance_rate,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true

  validates :insurance_rate_type,
            inclusion: { in: %w[level_term decreasing_life] },
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

  validates :start_date, presence: true, on: :create

  def set_default_start_date
    self.start_date ||= Date.current
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  def monthly_payment
    return unless term_months && interest_rate && rate_type == "fixed"

    balance_cents = original_balance.amount
    months        = term_months
    currency      = account.currency

    return Money.new(0, currency) if balance_cents.zero? || months.zero?

    balance = BigDecimal(balance_cents)
    rate    = BigDecimal(interest_rate) / 1200

    payment =
      if rate.zero?
        balance / months
      else
        factor = (1 + rate) ** months
        balance * rate * factor / (factor - 1)
      end

    Money.new(payment.round(0).to_i, currency)
  end

  def months_elapsed(as_of: Date.current)
    start = start_date
    term  = term_months

    return 0 unless start && term
    return 0 if as_of < start

    months = (as_of.year * 12 + as_of.month) - (start.year * 12 + start.month)
    months -= 1 if start + months.months > as_of

    months.clamp(0, term)
  end


  def remaining_months(as_of: Date.current)
    term = term_months
    return unless term

    [ term - months_elapsed(as_of:), 0 ].max
  end

  def finished?(as_of: Date.current)
    term = term_months
    term && months_elapsed(as_of:) >= term
  end

  def amortization_schedule
    return [] unless term_months && interest_rate && start_date && rate_type == "fixed"
    Rails.cache.fetch([ "loan_amortization", cache_key_with_version ]) do
      generate_amortization_schedule
    end
  end

  def payment_date_for(month_number)
    start = start_date
    return unless start && month_number&.positive?
    start + (month_number - 1).months
  end


  def generate_amortization_schedule
    return [] if interest_rate.nil? || term_months.nil? || start_date.nil?

    balance          = BigDecimal(original_balance.amount.to_s)
    initial_balance  = balance

    rate             = BigDecimal(interest_rate.to_s) / 1200
    insurance_rate_m = BigDecimal((insurance_rate || 0).to_s) / 1200

    return [] unless (monthly = monthly_payment)
    payment = BigDecimal(monthly.amount.to_s)

    schedule = []
    months   = term_months
    date     = start_date

    months.times do |i|
      interest = (balance * rate).round(0)

      insurance_base =
        insurance_rate_type == "level_term" ? initial_balance : nil
      base = insurance_base || balance
      insurance_amount = (base * insurance_rate_m).round(0)

      principal = payment - interest
      balance   = [ balance - principal, 0 ].max

      schedule << {
        month: i + 1,
        date: date,
        payment: payment.to_i,
        interest: interest.to_i,
        principal: principal.to_i,
        insurance: insurance_amount.to_i,
        remaining_balance: balance.round(0).to_i
      }

      date = date.next_month
    end

    schedule
  end

  def total_insurance
    Money.new(amortization_schedule.sum { _1[:insurance] }, account.currency)
  end

  def total_paid
    return unless (mp = monthly_payment) && term_months
    mp * term_months
  end

  def total_interest
    return unless (tp = total_paid) && (ob = original_balance)
    tp - ob
  end

  def total_cost
    ti = total_interest
    return nil unless ti

    ti + total_insurance
  end

  def remaining_balance_at(month_number)
    return unless month_number&.positive?
    row = amortization_schedule[month_number - 1]
    return unless row

    Money.new(row[:remaining_balance].round, account.currency)
  end

  def payment_breakdown(month_number: nil)
    month_number ||= months_elapsed(as_of: Date.current)
    month_number   = month_number.clamp(1, term_months || 1)

    row = amortization_schedule[month_number - 1] or return

    currency  = account.currency
    principal = Money.new(row[:principal], currency)
    interest  = Money.new(row[:interest],  currency)
    insurance = Money.new(row[:insurance], currency)
    total     = principal + interest + insurance

    ratios =
      if total.amount.positive?
        total_f = total.to_f

        {
          principal: principal.to_f / total_f,
          interest:  interest.to_f  / total_f,
          insurance: insurance.to_f / total_f
        }
      else
        { principal: 0.0, interest: 0.0, insurance: 0.0 }
      end
    {
      month:     month_number,
      date:      row[:date],
      principal: principal,
      interest:  interest,
      insurance: insurance,
      total:     total,
      ratios:    ratios
    }
  end

  def elapsed_ratio
    term = term_months
    return unless term&.positive?

    (months_elapsed.fdiv(term)).clamp(0.0, 1.0)
  end


  def initial_leverage_ratio
    dp = down_payment
    return unless dp&.positive?

    original_balance.to_f.fdiv(dp)
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
