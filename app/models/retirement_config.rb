class RetirementConfig < ApplicationRecord
  PENSION_SYSTEMS = %w[de_grv custom].freeze
  DEFAULT_RENTENWERT = 39.32 # Updated annually by German government (as of 2025)
  SAFE_WITHDRAWAL_RATE = 0.04 # 4% rule for safe withdrawal

  belongs_to :family
  has_many :pension_entries, dependent: :destroy

  validates :country, presence: true
  validates :pension_system, inclusion: { in: PENSION_SYSTEMS }
  validates :birth_year, presence: true,
            numericality: { greater_than: 1900, less_than_or_equal_to: -> { Date.current.year } }
  validates :retirement_age, presence: true,
            numericality: { greater_than_or_equal_to: 50, less_than_or_equal_to: 80 }
  validates :target_monthly_income, presence: true, numericality: { greater_than: 0 }
  validates :expected_return_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 30 }
  validates :inflation_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 20 }
  validates :tax_rate_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  # Current age based on birth year
  def current_age
    Date.current.year - birth_year
  end

  # Years until retirement
  def years_to_retirement
    [ retirement_age - current_age, 0 ].max
  end

  # Whether the user has already reached retirement age
  def retired?
    current_age >= retirement_age
  end

  # Estimated monthly pension.
  # GRV: calculated from Entgeltpunkte × Rentenwert, with latest statement override.
  # Custom: uses latest pension entry's projected value if available, otherwise 0.
  def estimated_monthly_pension
    if latest_pension_entry&.projected_monthly_pension
      return latest_pension_entry.projected_monthly_pension
    end

    return 0 unless pension_system == "de_grv"

    points = total_projected_points
    rw = rentenwert || DEFAULT_RENTENWERT
    points * rw
  end

  # Total projected pension points at retirement
  def total_projected_points
    current = latest_pension_entry&.current_points || 0
    annual = expected_annual_points || 1.0
    current + (annual * years_to_retirement)
  end

  # Monthly pension gap: how much more you need beyond GRV pension
  def monthly_pension_gap
    gap = target_monthly_income - estimated_monthly_pension_after_tax
    [ gap, 0 ].max
  end

  # Estimated pension after taxes
  def estimated_monthly_pension_after_tax
    estimated_monthly_pension * (1 - (tax_rate_pct / 100.0))
  end

  # Capital needed to fill the pension gap (inflation-adjusted)
  # Using the 4% rule (or custom withdrawal rate based on expected return)
  def capital_needed_for_gap
    return 0 if monthly_pension_gap <= 0

    # Adjust for inflation over years to retirement
    inflation_factor = (1 + inflation_pct / 100.0) ** years_to_retirement
    future_monthly_gap = monthly_pension_gap * inflation_factor
    future_annual_gap = future_monthly_gap * 12

    future_annual_gap / SAFE_WITHDRAWAL_RATE
  end

  # How much you need to save monthly to reach the required capital
  def required_monthly_savings
    return 0 if capital_needed_for_gap <= 0 || years_to_retirement <= 0

    # Future value of annuity formula
    monthly_return = (expected_return_pct / 100.0) / 12
    months = years_to_retirement * 12

    if monthly_return > 0
      capital_needed_for_gap / (((1 + monthly_return) ** months - 1) / monthly_return)
    else
      capital_needed_for_gap / months
    end
  end

  # Current investment portfolio value from accounts (converted to family currency)
  def current_portfolio_value
    accounts = family.accounts
      .where(accountable_type: %w[Investment Depository])
      .where(status: %w[draft active])
      .to_a

    return 0 if accounts.empty?

    foreign_currencies = accounts.filter_map { |a| a.currency if a.currency != family.currency }
    rates = foreign_currencies.present? ? ExchangeRate.rates_for(foreign_currencies, to: family.currency, date: Date.current) : {}

    accounts.sum(BigDecimal("0")) do |account|
      if account.currency == family.currency
        account.balance
      else
        account.balance * (rates[account.currency] || 1)
      end
    end
  end

  # FIRE number: capital needed for financial independence
  # Accounts for expected pension income to avoid overstating the target
  def fire_number
    annual_gap = (target_monthly_income - estimated_monthly_pension_after_tax) * 12
    annual_gap = [ annual_gap, 0 ].max
    inflation_factor = (1 + inflation_pct / 100.0) ** years_to_retirement
    future_annual_gap = annual_gap * inflation_factor
    future_annual_gap / SAFE_WITHDRAWAL_RATE
  end

  # FIRE progress percentage
  def fire_progress_pct
    return 100 if fire_number <= 0
    [ (current_portfolio_value / fire_number * 100).round(1), 100 ].min
  end

  # Estimated FIRE date
  def estimated_fire_date
    return Date.current if fire_progress_pct >= 100

    monthly_return = (expected_return_pct / 100.0) / 12
    current = current_portfolio_value
    target = fire_number
    monthly_saving = current_monthly_savings.to_f

    return nil if monthly_return <= 0 && monthly_saving <= 0

    # Iterative calculation
    months = 0
    while current < target && months < 600 # Max 50 years
      current = current * (1 + monthly_return) + monthly_saving
      months += 1
    end

    months < 600 ? Date.current + months.months : nil
  end

  # Returns pension entries in reverse-chronological order with precomputed
  # point deltas, avoiding the N+1 that PensionEntry#points_gained causes.
  # Each element responds to .points_gained without an extra query.
  def pension_entries_with_gains
    sorted = pension_entries.chronological.to_a
    sorted.each_with_index do |entry, idx|
      prev = idx > 0 ? sorted[idx - 1] : nil
      delta = prev ? entry.current_points - prev.current_points : entry.current_points
      entry.define_singleton_method(:points_gained) { delta }
    end
    sorted.reverse
  end

  private

    def latest_pension_entry
      @latest_pension_entry ||= pension_entries.order(recorded_at: :desc).first
    end
end
