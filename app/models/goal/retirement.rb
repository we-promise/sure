class Goal::Retirement < Goal
  ADJUSTMENTS_LIMIT = 10

  DEFAULT_RETIRE_AGE = 65
  DEFAULT_TERMINAL_AGE = 95
  DEFAULT_REAL_RETURN_PCT = 5.0

  store_accessor :retirement_params,
    :birth_year, :retire_age, :real_return_pct, :monthly_savings,
    :target_spend, :terminal_age

  belongs_to :owner, class_name: "User", foreign_key: :user_id

  has_many :pension_sources, foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :statements, class_name: "Goal::RetirementStatement",
    foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :adjustments, class_name: "Goal::RetirementAdjustment",
    foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :retirement_bucket_entries, foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :bucket_accounts, through: :retirement_bucket_entries, source: :account

  validates :owner, presence: true
  validate :owner_belongs_to_family
  validate :adjustments_within_limit

  # One retirement plan per user. Bootstrapped on first visit so pension
  # sources, statements, and bucket entries always have a parent. The
  # target is derived by the forecast (PR3), so no target_amount here.
  def self.for_owner(user)
    find_or_create_by!(user_id: user.id, family_id: user.family_id) do |plan|
      plan.name = "Retirement"
      plan.currency = user.family.primary_currency_code
    end
  end

  def editable_by?(user)
    return false if user.nil?
    user_id == user.id
  end

  def target_amount_required?
    false
  end

  # --- Forecast inputs -------------------------------------------------

  def current_age
    year = birth_year.presence&.to_i
    return nil if year.nil? || year.zero?
    Date.current.year - year
  end

  def effective_retire_age
    (retire_age.presence || DEFAULT_RETIRE_AGE).to_i
  end

  def effective_terminal_age
    (terminal_age.presence || DEFAULT_TERMINAL_AGE).to_i
  end

  def effective_real_return
    (real_return_pct.presence || DEFAULT_REAL_RETURN_PCT).to_d / 100
  end

  def monthly_savings_amount
    (monthly_savings.presence || 0).to_d
  end

  # Plan currency / today's money. Falls back to the family spending anchor.
  def target_spend_monthly
    target_spend.presence&.to_d || family.retirement_spending_baseline(user: owner).amount
  end

  # Sum of selected accounts. v1 assumes the plan currency; cross-currency
  # FX of the bucket is a v1.1 follow-up.
  def bucket_value
    bucket_accounts.sum { |account| account.balance.to_d }
  end

  def payouts
    pension_sources.map { |source| ::Retirement::Fire::Payout.from_source(source) }
  end

  def forecast_adjustments
    adjustments.map do |adjustment|
      ::Retirement::Fire::Adjustment.new(
        from_age: adjustment.from_age,
        to_age: adjustment.to_age,
        annual_amount: adjustment.amount_today.to_d * 12
      )
    end
  end

  def forecast_inputs
    retire = effective_retire_age
    current = current_age
    ::Retirement::Fire::Inputs.new(
      current_age: current,
      retire_age: retire,
      terminal_age: effective_terminal_age,
      real_return: effective_real_return,
      annual_savings: monthly_savings_amount * 12,
      annual_target_spend: target_spend_monthly * 12,
      starting_portfolio: bucket_value,
      retire_year: Date.current.year + (retire - current),
      payouts: payouts,
      target_adjustments: forecast_adjustments
    )
  end

  # Returns nil until a birth year is set (age is required to project).
  def forecast
    return nil if current_age.nil?
    @forecast ||= ::Retirement::Fire::Forecast.new(forecast_inputs).call
  end

  # Date the user can stop working, derived from retire_age.
  def freedom_date
    return nil if current_age.nil?
    Date.new(birth_year.to_i + effective_retire_age, 1, 1)
  end

  def coast_fire_date
    age = forecast&.coast_age
    return nil if age.nil?
    Date.new(birth_year.to_i + age, 1, 1)
  end

  private
    # Retirement uses RetirementBucketEntry for asset selection, not the
    # goal_accounts depository join, so the parent validations (which run
    # against goal_accounts) would always fail. No-op them on the subtype.
    def must_have_at_least_one_linked_account
    end

    def linked_accounts_must_be_depository
    end

    def owner_belongs_to_family
      return if owner.nil? || family_id.nil?
      errors.add(:owner, :must_belong_to_family) unless owner.family_id == family_id
    end

    def adjustments_within_limit
      return if adjustments.reject(&:marked_for_destruction?).size <= ADJUSTMENTS_LIMIT
      errors.add(:adjustments, :too_many, count: ADJUSTMENTS_LIMIT)
    end
end
