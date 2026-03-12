class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

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

  validates :insurance_rate,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true

  validates :insurance_rate_type,
            inclusion: { in: %w[fixed variable] },
            allow_nil: true

  validates :start_date, allow_nil: true

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    annual_rate = interest_rate / 100.0
    monthly_rate = annual_rate / 12.0

    # balance_amount est en centimes — on calcule directement en centimes
    payment_in_cents =
      if monthly_rate.zero?
        balance_amount.to_f / term_months
      else
        (
          balance_amount.to_f *
          monthly_rate *
          (1 + monthly_rate)**term_months
        ) / ((1 + monthly_rate)**term_months - 1)
      end

    Money.new(payment_in_cents.round, account.currency)
  end

  # -- Progression -----------------------------------------------------------

  def months_elapsed(as_of: Date.current)
    return 0 unless start_date
    return 0 if as_of < start_date

    years_diff  = as_of.year  - start_date.year
    months_diff = as_of.month - start_date.month

    elapsed = years_diff * 12 + months_diff

    # Si le jour du mois n'est pas encore atteint, on enlève 1
    elapsed -= 1 if as_of.day < start_date.day

    elapsed.clamp(0, term_months || 0)
  end

  def remaining_months(as_of: Date.current)
    return nil unless term_months

    remaining = term_months - months_elapsed(as_of:)
    remaining.positive? ? remaining : 0
  end

  def finished?(as_of: Date.current)
    remaining_months(as_of:) == 0
  end


  # -- Tableau d'amortissement ----------------------------------------------

  def amortization_schedule
    return [] unless term_months && interest_rate && rate_type == "fixed"

    Rails.cache.fetch([ "loan_amortization", cache_key_with_version ]) do
      generate_amortization_schedule
    end
  end

  def payment_date_for(month_number)
    return nil unless start_date

    start_date + (month_number - 1).months
  end

  def generate_amortization_schedule
    # Tous les montants intermédiaires sont en centimes
    balance              = original_balance.amount.to_f
    monthly_rate         = (interest_rate / 100.0) / 12.0
    monthly_insurance_rate = (insurance_rate.to_f / 100.0) / 12.0
    payment              = monthly_payment.amount.to_f

    schedule = []

    term_months.times do |month|
      interest  = balance * monthly_rate
      principal = payment - interest
      insurance = balance * monthly_insurance_rate

      new_balance = [ balance - principal, 0.0 ].max

      schedule << {
        month:             month + 1,
        date:              payment_date_for(month + 1),
        payment:           payment.round,
        interest:          interest.round,
        principal:         principal.round,
        insurance:         insurance.round,
        remaining_balance: new_balance.round
      }

      balance = new_balance
    end

    schedule
  end

  # -- Agrégats financiers --------------------------------------------------

  def total_insurance
    # Les valeurs du schedule sont déjà en centimes
    sum_cents = amortization_schedule.sum { |m| m[:insurance] }
    Money.new(sum_cents.round, account.currency)
  end

  def total_paid
    mp = monthly_payment
    return nil unless mp && term_months.present?

    mp * term_months
  end

  def total_interest
    tp = total_paid
    ob = original_balance
    return nil unless tp && ob

    tp - ob
  end

  def total_cost
    ti = total_interest
    return nil unless ti

    ti + total_insurance
  end

  def remaining_balance_at(month_number)
    row = amortization_schedule[month_number - 1]
    return nil unless row

    # remaining_balance est déjà en centimes
    Money.new(row[:remaining_balance].round, account.currency)
  end

  # -- Décomposition d'un paiement mensuel --
  def payment_breakdown(month_number: nil)
    month_number ||= months_elapsed(as_of: Date.current)
    month_number   = month_number.clamp(1, term_months || 1)

    row = amortization_schedule[month_number - 1]
    return nil unless row

    currency   = account.currency
    principal  = Money.new(row[:principal], currency)
    interest   = Money.new(row[:interest],  currency)
    insurance  = Money.new(row[:insurance], currency)
    total      = principal + interest + insurance

    ratios =
      if total.positive?
        {
          principal: principal.to_f / total.to_f,
          interest:  interest.to_f  / total.to_f,
          insurance: insurance.to_f / total.to_f
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

  # -- Ratios ---------------------------------------------------------------

  def interest_ratio
    tp = total_paid
    ti = total_interest
    return nil unless tp && ti
    return nil if tp.zero?

    ti.to_f / tp.to_f
  end

  def initial_leverage_ratio
    return nil if down_payment.nil? || down_payment.zero?

    original_balance.to_f / down_payment.to_f
  end

  # -- Méthodes de classe ---------------------------------------------------

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
