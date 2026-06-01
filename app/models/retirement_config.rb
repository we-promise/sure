class RetirementConfig < ApplicationRecord
  PENSION_SYSTEMS = {
    "custom"    => { calculator: "RetirementConfig::PensionCalculator::Custom" },
    "de_grv"    => { calculator: "RetirementConfig::PensionCalculator::DeGrv" },
    "us_ss"     => { calculator: "RetirementConfig::PensionCalculator::UsSocialSecurity" },
    "uk_sp"     => { calculator: "RetirementConfig::PensionCalculator::UkStatePension" },
    "fr_regime" => { calculator: "RetirementConfig::PensionCalculator::FrRegimeGeneral" },
    "es_ss"     => { calculator: "RetirementConfig::PensionCalculator::EsSocialSecurity" }
  }.freeze

  PENSION_SYSTEM_GROUPS = {
    "europe"         => %w[de_grv fr_regime es_ss],
    "united_kingdom" => %w[uk_sp],
    "north_america"  => %w[us_ss],
    "other"          => %w[custom]
  }.freeze

  COUNTRY_TO_PENSION_SYSTEM = {
    "DE" => "de_grv", "AT" => "de_grv",
    "US" => "us_ss",  "CA" => "us_ss",
    "GB" => "uk_sp",
    "FR" => "fr_regime",
    "ES" => "es_ss"
  }.freeze

  SAFE_WITHDRAWAL_RATE = 0.04

  def self.suggest_pension_system(country)
    COUNTRY_TO_PENSION_SYSTEM.fetch(country.to_s.upcase, "custom")
  end

  belongs_to :family
  has_many :pension_entries, dependent: :destroy

  validates :country, presence: true
  validates :pension_system, inclusion: { in: PENSION_SYSTEMS.keys }
  validates :birth_year, presence: true,
            numericality: { greater_than: 1900, less_than_or_equal_to: -> { Date.current.year } }
  validates :retirement_age, presence: true,
            numericality: { greater_than_or_equal_to: 50, less_than_or_equal_to: 80 }
  validates :target_monthly_income, presence: true, numericality: { greater_than: 0 }
  validates :expected_return_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 30 }
  validates :inflation_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 20 }
  validates :tax_rate_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  def current_age
    Date.current.year - birth_year
  end

  def years_to_retirement
    [ retirement_age - current_age, 0 ].max
  end

  def retired?
    current_age >= retirement_age
  end

  def estimated_monthly_pension
    pension_calculator.estimated_monthly_pension
  end

  def pension_calculator
    @pension_calculator ||= begin
      klass_name = PENSION_SYSTEMS.dig(pension_system, :calculator)
      klass_name.constantize.new(self)
    end
  end

  # Whether the current system uses pension points (e.g. DE Entgeltpunkte)
  def points_based?
    pension_calculator.points_based?
  end

  # Read a system-specific parameter from JSONB
  def pension_param(key)
    pension_params&.dig(key.to_s)
  end

  def monthly_pension_gap
    gap = target_monthly_income - estimated_monthly_pension_after_tax
    [ gap, 0 ].max
  end

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
      if points_based? && entry.current_points
        delta = prev&.current_points ? entry.current_points - prev.current_points : entry.current_points
      else
        delta = nil
      end
      entry.define_singleton_method(:points_gained) { delta }
    end
    sorted.reverse
  end

  private

    def latest_pension_entry
      return @latest_pension_entry if defined?(@latest_pension_entry)
      @latest_pension_entry = pension_entries.order(recorded_at: :desc).first
    end
end
