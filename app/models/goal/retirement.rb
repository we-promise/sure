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

  # Retire age never earlier than today, so the forecast and the
  # freedom-date KPI agree and neither emits a past year.
  def clamped_retire_age
    return effective_retire_age if current_age.nil?
    [ effective_retire_age, current_age ].max
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

  # The 25× rule of thumb: the portfolio that sustains the target spend at a
  # 4% withdrawal rate. A tertiary stat next to the spending anchor.
  def fi_number
    (target_spend_monthly.to_d * 12 * 25).to_i
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
    current = current_age
    retire = clamped_retire_age
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

  # Date the user can stop working, derived from the (clamped) retire age.
  def freedom_date
    return nil if current_age.nil?
    Date.new(birth_year.to_i + clamped_retire_age, 1, 1)
  end

  def coast_fire_date
    age = forecast&.coast_age
    return nil if age.nil?
    Date.new(birth_year.to_i + age, 1, 1)
  end

  # One-time lump payouts as chart markers (age + amount).
  def lump_markers
    payouts.filter_map do |payout|
      next unless %w[lump_sum lump_plus_annuity].include?(payout.shape)
      amount = payout.shape == "lump_sum" ? payout.monthly_amount : payout.lump_amount
      next if amount.to_d.zero?
      { age: payout.start_age, amount: amount.to_i }
    end
  end

  # Everything the glide chart needs, pre-derived from the forecast: the
  # active plan, a zero-savings shadow (Walletburst), a ±1pp real-return
  # band, the per-age income breakdown for the hover tooltip, lump
  # markers, and the retire/coast crossover points. nil until projectable.
  def glide_payload
    base = forecast
    return nil if base.nil?

    inputs = forecast_inputs
    shadow = ::Retirement::Fire::Forecast.new(inputs.with(annual_savings: 0)).call
    band_low = ::Retirement::Fire::Forecast.new(inputs.with(real_return: inputs.real_return - 0.01)).call
    band_high = ::Retirement::Fire::Forecast.new(inputs.with(real_return: inputs.real_return + 0.01)).call

    {
      currency_symbol: Money.new(0, currency).currency.symbol,
      current_age: current_age,
      retire_age: clamped_retire_age,
      terminal_age: effective_terminal_age,
      coast_age: base.coast_age,
      money_lasts_to_age: base.money_lasts_to_age,
      lasts_past_terminal: base.lasts_past_terminal?,
      target_monthly: target_spend_monthly.to_i,
      retire_value: base.portfolio_at_retirement(clamped_retire_age),
      series: base.glide.map { |age, value| { age: age, value: value } },
      shadow_series: shadow.glide.map { |age, value| { age: age, value: value } },
      band_low: band_low.glide.map { |age, value| { age: age, value: value } },
      band_high: band_high.glide.map { |age, value| { age: age, value: value } },
      income: base.income_by_year.map do |row|
        {
          age: row[:age], state: row[:state], workplace: row[:workplace],
          other: row[:other], drawdown: row[:drawdown], shortfall: row[:shortfall],
          covered: row[:shortfall] <= 0
        }
      end,
      lumps: lump_markers
    }
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
