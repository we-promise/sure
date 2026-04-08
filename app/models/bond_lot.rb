class BondLot < ApplicationRecord
  belongs_to :bond
  belongs_to :entry, optional: true

  TAX_STRATEGIES = %w[standard reduced exempt].freeze
  DEFAULT_TAX_RATE_PERCENT = 19
  TOP_LOTS_LIMIT = 5

  scope :open, -> { where(closed_on: nil) }

  def self.needs_rate_review
    with_inflation_lookup_cache do
      unresolved_ids = []
      open.where(subtype: Bond::INFLATION_LINKED_SUBTYPES).includes(:bond).find_in_batches(batch_size: 200) do |batch|
        batch.each do |lot|
          review_on = [ Date.current, lot.maturity_date ].compact.min
          unresolvable = (lot.needs_first_period_rate?(on: review_on) && lot.first_period_rate.blank?) ||
            !lot.rates_resolvable_through?(date: review_on, allow_import: false)
          unresolved_ids << lot.id if unresolvable
        end
      end

      ids = unresolved_ids.uniq
      ids.empty? ? none : open.where(id: ids)
    end
  end

  # Returns an OpenStruct with :total_value, :total_return, :top_lots
  # for the dashboard summary card.
  def self.dashboard_summary(bond_accounts, family_currency)
    with_inflation_lookup_cache do
      lots_relation = open
        .joins(bond: :account)
        .includes(bond: :account)
        .where(accounts: { id: bond_accounts.select(:id) })

      total_value = 0.to_d
      total_return = 0.to_d
      top_enriched = []

      lots_relation.find_each(batch_size: 200) do |lot|
        account = lot.account
        lot_value = lot.estimated_current_value(allow_import: false).to_d
        lot_return = lot_value - lot.amount.to_d
        converted_value = Money.new(lot_value, account.currency).exchange_to(family_currency, fallback_rate: 1).amount
        converted_return = Money.new(lot_return, account.currency).exchange_to(family_currency, fallback_rate: 1).amount

        total_value += converted_value
        total_return += converted_return

        top_enriched << [ account, lot, converted_value ]
        if top_enriched.size > TOP_LOTS_LIMIT
          top_enriched.sort_by! { |_, _, cv| cv }
          top_enriched.shift
        end
      end

      top_lots = top_enriched
        .sort_by { |_, _, cv| -cv }
        .map { |account, lot, _| [ account, lot ] }

      OpenStruct.new(total_value: total_value, total_return: total_return, top_lots: top_lots)
    end
  end

  def self.with_inflation_lookup_cache
    previous_cache = Thread.current[:bond_inflation_record_cache]
    Thread.current[:bond_inflation_record_cache] = {}
    yield
  ensure
    Thread.current[:bond_inflation_record_cache] = previous_cache
  end

  before_validation :inherit_defaults_from_bond
  before_validation :normalize_legacy_subtype
  before_validation :normalize_subtype_from_product
  before_validation :apply_product_defaults
  before_validation :assign_maturity_date_from_term
  before_validation :derive_amount_from_units
  before_validation :normalize_auto_fetch_inflation
  before_validation :normalize_inflation_provider
  before_validation :normalize_tax_settings
  before_validation :clear_rate_review_flag

  after_commit :enqueue_inflation_backfill, on: %i[create update], if: :should_enqueue_inflation_backfill?
  after_commit :settle_if_already_matured!, on: %i[create update], if: :should_settle_if_already_matured?

  validates :purchased_on, :amount, :subtype, presence: true
  validates :auto_fetch_inflation, inclusion: { in: [ true, false ] }
  validates :amount, numericality: { greater_than: 0 }
  validates :term_months, presence: true
  validates :term_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :interest_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :first_period_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :inflation_margin, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :inflation_rate_assumption, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :early_redemption_fee, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :units, numericality: { greater_than: 0 }, allow_nil: true
  validates :nominal_per_unit, numericality: { greater_than: 0 }, allow_nil: true
  validates :cpi_lag_months, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :subtype, inclusion: { in: Bond::SUBTYPES.keys }
  validates :product_code, inclusion: { in: Bond::PRODUCT_DEFAULTS.keys }, allow_blank: true
  validates :inflation_provider, inclusion: { in: Bond::InflationProvider::PROVIDERS.keys }, allow_blank: true
  validates :rate_type, inclusion: { in: Bond::RATE_TYPES }, allow_nil: true
  validates :coupon_frequency, inclusion: { in: Bond::COUPON_FREQUENCIES }, allow_nil: true
  validates :tax_strategy, inclusion: { in: TAX_STRATEGIES }
  validates :tax_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :entry_id, uniqueness: true, allow_nil: true
  validate :validate_issue_date_not_after_purchased_on
  validate :validate_maturity_date_not_before_purchased_on

  with_options if: :inflation_linked? do
    validates :issue_date, presence: true
    validates :units, presence: true
    validates :nominal_per_unit, presence: true
    validates :first_period_rate, presence: true, if: -> { needs_first_period_rate? && !requires_rate_review? }
    validates :inflation_margin, presence: true, unless: :requires_rate_review?
    validates :cpi_lag_months, presence: true
    validates :inflation_rate_assumption, presence: true, unless: -> { auto_fetch_inflation? || requires_rate_review? }
  end

  with_options unless: :inflation_linked? do
    validates :interest_rate, presence: true, unless: -> { requires_rate_review? || inflation_linked_selection? }
    validates :rate_type, presence: true
    validates :coupon_frequency, presence: true
  end

  delegate :account, to: :bond

  def open?
    closed_on.blank?
  end

  def matured?(on: Date.current)
    maturity_date.present? && on >= maturity_date
  end

  def inflation_linked?
    canonical_subtype.in?(Bond::INFLATION_LINKED_SUBTYPES)
  end

  def inflation_linked_selection?
    return true if inflation_linked?

    preset_subtype = Bond::PRODUCT_DEFAULTS.dig(product_code, :subtype)
    preset_subtype == "inflation_linked"
  end

  def auto_fetch_inflation?
    inflation_linked? && auto_fetch_inflation
  end

  def in_first_rate_period?(on: Date.current)
    return false if purchased_on.blank?

    period_base = issue_date.presence || purchased_on
    on < period_base + 1.year
  end

  def current_cpi_reference_on(on: Date.current)
    return nil unless inflation_linked?

    rate_period_start = current_rate_period_start(on:)
    return nil if rate_period_start.blank?

    rate_period_start.beginning_of_month - cpi_lag_months.to_i.months
  end

  def needs_first_period_rate?(on: purchased_on || Date.current)
    inflation_linked? && in_first_rate_period?(on:)
  end

  def estimated_current_value(on: Date.current, allow_import: true)
    principal = amount.to_d
    return principal if principal.zero? || purchased_on.blank?

    period_end = [ on, maturity_date ].compact.min
    return principal if period_end.blank? || period_end <= purchased_on

    value = principal
    unpaid_coupon_accrual = 0.to_d
    cursor = purchased_on
    issue_base = anniversary_issue_base

    while cursor < period_end
      next_accrual_boundary, _accrual_start = accrual_boundaries(cursor:, issue_base:)
      next_anniversary, anniversary_start = anniversary_boundaries(cursor:, issue_base:)

      next_cursor = [ next_accrual_boundary, period_end ].min
      days_in_step = [ (next_cursor - cursor).to_i, 0 ].max
      break if days_in_step.zero?

      annual_rate_decimal = annual_rate_for(on: cursor, allow_import:)
      break if annual_rate_decimal.blank?

      days_in_year = [ (next_anniversary - anniversary_start).to_i, 1 ].max
      interest_earned = value * annual_rate_decimal * (days_in_step.to_d / days_in_year)
      if coupon_reinvested?
        value += interest_earned
      else
        unpaid_coupon_accrual = coupon_paid_before_maturity?(next_cursor:, next_accrual_boundary:) ? 0.to_d : interest_earned
      end

      cursor = next_cursor
    end

    value + unpaid_coupon_accrual
  end

  def total_return_amount(on: Date.current, allow_import: true)
    estimated_current_value(on:, allow_import:) - amount.to_d
  end

  def total_return_percent(on: Date.current, allow_import: true)
    principal = amount.to_d
    return 0 if principal.zero?

    (total_return_amount(on:, allow_import:) / principal) * 100
  end

  def projected_total_return_amount(allow_import: true)
    maturity = maturity_date || (purchased_on + term_months.to_i.months if term_months.present?)
    return 0.to_d if maturity.blank?

    estimated_current_value(on: maturity, allow_import:) - amount.to_d
  end

  def projected_total_return_percent(allow_import: true)
    principal = amount.to_d
    return 0 if principal.zero?

    (projected_total_return_amount(allow_import:) / principal) * 100
  end

  def coupon_amount_per_period(on: Date.current)
    return nil if coupon_frequency.blank? || coupon_frequency == "at_maturity"

    periods = {
      "monthly" => 12,
      "quarterly" => 4,
      "semi_annual" => 2,
      "annual" => 1
    }
    per_year = periods[coupon_frequency]
    return nil if per_year.blank?

    annual_rate_decimal = if inflation_linked?
      annual_rate_for(on:)
    else
      interest_rate&.to_d&./(100)
    end
    return nil if annual_rate_decimal.blank?

    Money.new((amount.to_d * annual_rate_decimal / per_year).round(4), account.currency)
  end

  def create_purchase_entry!(auto_purchased: false, requires_rate_review: false)
    raise ArgumentError, "BondLot must be persisted before creating purchase entry" unless persisted?

    ActiveRecord::Base.transaction do
      created_entry = account.entries.create!(
        date: purchased_on,
        name: I18n.t("bond_lots.activity.purchase_name", subtype: subtype_label),
        amount: amount,
        currency: account.currency,
        entryable: Transaction.new(
          kind: :funds_movement,
          extra: purchase_entry_extra(auto_purchased:, requires_rate_review:)
        )
      )

      created_entry.lock_saved_attributes!
      created_entry.mark_user_modified!

      update!(entry: created_entry)
      created_entry
    end
  end

  def save_with_purchase_entry!
    ActiveRecord::Base.transaction do
      save!
      create_purchase_entry!
    end
  end

  def update_purchase_entry!
    return unless entry

    existing_extra = entry.entryable&.extra || {}
    entry.update!(
      date: purchased_on,
      name: I18n.t("bond_lots.activity.purchase_name", subtype: subtype_label),
      amount: amount,
      entryable_attributes: {
        id: entry.entryable_id,
        extra: existing_extra.merge(purchase_entry_extra)
      }
    )
    entry.lock_saved_attributes!
    entry.mark_user_modified!
  end

  def update_with_purchase_entry!(attributes)
    with_lock do
      ActiveRecord::Base.transaction do
        update!(attributes)
        update_purchase_entry!
      end
    end
  end

  def destroy_with_purchase_entry!
    ActiveRecord::Base.transaction do
      purchase_entry = entry

      destroy!
      purchase_entry.destroy! if purchase_entry && !purchase_entry.destroyed?
    end
  end

  def current_rate_percent(on: Date.current, allow_import: true)
    annual_rate_for(on:, allow_import:)&.*(100)
  end

  def current_inflation_component_percent(on: Date.current, allow_import: true)
    return nil unless inflation_linked?

    rate_context_for(on:, allow_import:)[:inflation_component_percent]
  end

  def current_inflation_source(on: Date.current, allow_import: true)
    return nil unless inflation_linked?

    source = rate_context_for(on:, allow_import:)[:inflation_source]
    source == "first_period" ? nil : source
  end

  def gus_inflation_source?(on: Date.current, allow_import: true)
    current_inflation_source(on:, allow_import:) == "gus_sdp"
  end

  def current_margin_percent(on: Date.current, allow_import: true)
    return nil unless inflation_linked?

    rate_context_for(on:, allow_import:)[:margin_component_percent]
  end

  def current_inflation_indicator_id
    return nil unless inflation_linked? && auto_fetch_inflation?

    return nil unless inflation_provider_key == "gus_sdp"

    ENV["GUS_SDP_CPI_INDICATOR_ID"].presence || Provider::GusSdp::DEFAULT_CPI_INDICATOR_ID
  end

  def settlement_tax_rate_percent
    return 0.to_d if tax_strategy == "exempt"

    rate = tax_rate.presence || DEFAULT_TAX_RATE_PERCENT
    rate.to_d
  end

  def settle_if_matured!(on: Date.current)
    settlement_date_for_sync = nil

    # Lock the row to prevent concurrent settlements.
    settled = with_lock do
      return false unless auto_close_on_maturity?
      return false unless open?
      return false unless matured?(on:)

      settlement_date = [ on, maturity_date ].compact.min

      # Abort if any rate period cannot be resolved — prevents closing the lot with a wrong value.
      unless rates_resolvable_through?(date: settlement_date)
        update_column(:requires_rate_review, true)
        return false
      end

      gross_value = estimated_current_value(on: settlement_date)
      gain = [ gross_value - amount.to_d, 0.to_d ].max
      tax_withheld_amount = (gain * settlement_tax_rate_percent / 100).round(4)
      net_value = (gross_value - tax_withheld_amount).round(4)

      ActiveRecord::Base.transaction do
        create_settlement_entry!(settlement_date:, net_value:, tax_withheld_amount:, gross_value:)
        update!(
          closed_on: settlement_date,
          settlement_amount: net_value,
          tax_withheld: tax_withheld_amount
        )
        create_reinvestment_lot!(settlement_date:, net_value:) if should_auto_buy_new_issue?(net_value:)
      end
      settlement_date_for_sync = settlement_date

      Rails.logger.info(
        "[BondSettlement] Settled lot_id=#{id} account_id=#{account.id}: " \
        "gross=#{gross_value} tax=#{tax_withheld_amount} net=#{net_value}"
      )
      true
    end

    account.sync_later(window_start_date: settlement_date_for_sync) if settled
    settled
  end

  def capitalization_history(on: Date.current)
    principal = amount.to_d
    return [] if principal.zero? || purchased_on.blank?

    history_end = [ on, maturity_date, closed_on ].compact.min
    return [] if history_end.blank? || history_end <= purchased_on

    events = []
    period_number = 1
    opening_balance = principal
    cursor = purchased_on
    issue_base = anniversary_issue_base

    while cursor < history_end
      next_accrual_boundary, _accrual_start = accrual_boundaries(cursor:, issue_base:)
      next_anniversary, anniversary_start = anniversary_boundaries(cursor:, issue_base:)

      next_cursor = [ next_accrual_boundary, history_end ].min
      days_in_step = [ (next_cursor - cursor).to_i, 0 ].max
      break if days_in_step.zero?

      rate_context = rate_context_for(on: cursor)
      annual_rate_decimal = rate_context[:annual_rate_decimal]
      break if annual_rate_decimal.blank?

      days_in_year = [ (next_anniversary - anniversary_start).to_i, 1 ].max
      full_year_capitalization = coupon_reinvested? && (days_in_step == days_in_year)
      interest_earned = opening_balance * annual_rate_decimal * (days_in_step.to_d / days_in_year)

      closing_balance = coupon_reinvested? ? opening_balance + interest_earned : opening_balance

      events << {
        period_number: period_number,
        start_on: cursor,
        end_on: next_cursor,
        annual_rate_percent: annual_rate_decimal * 100,
        inflation_component_percent: rate_context[:inflation_component_percent],
        margin_component_percent: rate_context[:margin_component_percent],
        inflation_source: rate_context[:inflation_source],
        inflation_reference_on: rate_context[:inflation_reference_on],
        inflation_indicator_id: rate_context[:inflation_indicator_id],
        opening_balance: opening_balance,
        interest_earned: interest_earned,
        closing_balance: closing_balance,
        full_year_capitalization: full_year_capitalization
      }

      opening_balance = closing_balance
      cursor = next_cursor
      period_number += 1
    end

    events
  end

  private
    def coupon_reinvested?
      coupon_frequency.to_s == "at_maturity"
    end

    def coupon_paid_before_maturity?(next_cursor:, next_accrual_boundary:)
      next_cursor == next_accrual_boundary && maturity_date.present? && next_cursor < maturity_date
    end

    def rate_context_for(on:, allow_import: true)
      if inflation_linked?
        inflation_linked_rate_context(on:, allow_import:)
      else
        annual_rate = interest_rate.presence || bond&.interest_rate
        {
          annual_rate_decimal: annual_rate&.to_d&./(100),
          inflation_component_percent: nil,
          margin_component_percent: nil,
          inflation_source: nil,
          inflation_reference_on: nil,
          inflation_indicator_id: nil
        }
      end
    end

    def annual_rate_for(on:, allow_import: true)
      rate_context_for(on:, allow_import:)[:annual_rate_decimal]
    end

    def anniversary_issue_base
      (inflation_linked? && issue_date.present?) ? issue_date : purchased_on
    end

    def current_rate_period_start(on:)
      return nil if purchased_on.blank?

      issue_base = anniversary_issue_base
      years_since = 0
      years_since += 1 while issue_base + (years_since + 1).years <= on
      issue_base + years_since.years
    end

    # Returns [next_anniversary, anniversary_start] for the period containing cursor.
    def anniversary_boundaries(cursor:, issue_base:)
      years_since = 0
      years_since += 1 while issue_base + years_since.years <= cursor
      [ issue_base + years_since.years, issue_base + (years_since - 1).years ]
    end

    # Returns [next_accrual_boundary, accrual_start] for the period containing cursor.
    def accrual_boundaries(cursor:, issue_base:)
      months = accrual_period_months
      periods_since = 0
      periods_since += 1 while issue_base + ((periods_since + 1) * months).months <= cursor
      [ issue_base + ((periods_since + 1) * months).months, issue_base + (periods_since * months).months ]
    end

    def accrual_period_months
      {
        "monthly" => 1,
        "quarterly" => 3,
        "semi_annual" => 6,
        "annual" => 12,
        "at_maturity" => 12
      }.fetch(coupon_frequency.to_s, 12)
    end

    def inflation_linked_rate_context(on:, allow_import: true)
      if purchased_on.blank?
        return {
          annual_rate_decimal: nil,
          inflation_component_percent: nil,
          margin_component_percent: nil,
          inflation_source: nil,
          inflation_reference_on: nil,
          inflation_indicator_id: nil
        }
      end

      rate_period_start = current_rate_period_start(on:)
      return { annual_rate_decimal: nil } if rate_period_start.blank?

      if needs_first_period_rate?(on: rate_period_start)
        {
          annual_rate_decimal: first_period_rate&.to_d&./(100),
          inflation_component_percent: nil,
          margin_component_percent: nil,
          inflation_source: "first_period",
          inflation_reference_on: nil,
          inflation_indicator_id: nil
        }
      else
        inflation_snapshot = inflation_snapshot_for(on: rate_period_start, allow_import:)
        inflation_component = inflation_snapshot[:inflation_component_percent]
        margin_component = inflation_margin&.to_d

        # Cannot compute rate without inflation component or margin — do not coerce nil values to 0.
        return { annual_rate_decimal: nil } if inflation_component.nil? || margin_component.nil?

        raw_rate = (inflation_component + margin_component) / 100
        # Apply 0% floor only for products where deflation protection applies (e.g. Polish treasury bonds).
        annual_rate = deflation_floor_applies? ? [ raw_rate, 0.to_d ].max : raw_rate

        {
          annual_rate_decimal: annual_rate,
          inflation_component_percent: inflation_component,
          margin_component_percent: margin_component,
          inflation_source: inflation_snapshot[:source],
          inflation_reference_on: inflation_snapshot[:reference_on],
          inflation_indicator_id: inflation_snapshot[:indicator_id]
        }
      end
    end

    def inflation_snapshot_for(on:, allow_import: true)
      reference_on = current_cpi_reference_on(on:)

      if auto_fetch_inflation?
        source_record = inflation_rate_record_for(on:, allow_import:)
        if source_record.present?
          return {
            inflation_component_percent: source_record.rate_yoy.to_d - 100,
            source: inflation_source_label,
            reference_on: reference_on || Date.new(source_record.year, source_record.month, 1),
            indicator_id: current_inflation_indicator_id
          }
        end
      end

      {
        inflation_component_percent: inflation_rate_assumption&.to_d,
        source: inflation_rate_assumption.present? ? "manual" : nil,
        reference_on: nil,
        indicator_id: nil
      }
    end

    def inherit_defaults_from_bond
      self.subtype ||= bond&.subtype
      self.rate_type ||= bond&.rate_type
      self.coupon_frequency ||= bond&.coupon_frequency
      self.interest_rate = bond.interest_rate if interest_rate.blank? && bond&.interest_rate.present?
      self.term_months ||= bond&.term_months
    end

    def normalize_legacy_subtype
      return if subtype.blank?

      mapped = Bond::LEGACY_SUBTYPE_ALIASES[subtype]
      return unless mapped

      self.product_code ||= (subtype == "eod" ? "pl_eod" : subtype == "rod" ? "pl_rod" : nil)
      self.subtype = mapped
    end

    def normalize_subtype_from_product
      return if product_code.blank?

      defaults = Bond::PRODUCT_DEFAULTS[product_code]
      return if defaults.blank?

      self.subtype = defaults[:subtype]
    end

    def apply_product_defaults
      return unless product_code.present?

      defaults = Bond::PRODUCT_DEFAULTS[product_code]
      return if defaults.blank?

      self.subtype = defaults[:subtype] if subtype.blank? || Bond::LEGACY_SUBTYPE_ALIASES.key?(subtype)
      self.term_months = defaults[:term_months] if defaults[:term_months].present?
      self.rate_type = defaults[:rate_type] if defaults[:rate_type].present?
      self.coupon_frequency = defaults[:coupon_frequency] if defaults[:coupon_frequency].present?
      self.cpi_lag_months = defaults[:cpi_lag_months] if defaults[:cpi_lag_months].present?
      self.inflation_provider = defaults[:inflation_provider] if defaults[:inflation_provider].present? && inflation_provider.blank?
      self.nominal_per_unit ||= 100
      self.issue_date ||= purchased_on
      self.auto_fetch_inflation = true if auto_fetch_inflation.nil?
    end

    def normalize_auto_fetch_inflation
      self.auto_fetch_inflation = true if auto_fetch_inflation.nil?
      return if inflation_linked?

      self.auto_fetch_inflation = false
      self.inflation_provider = nil
    end

    def normalize_inflation_provider
      inflation_like = canonical_subtype.in?(Bond::INFLATION_LINKED_SUBTYPES)
      self.inflation_provider = nil unless inflation_like
      # Blank provider is treated as manual CPI mode only when global import is enabled.
      # When global import is disabled, we keep auto_fetch_inflation as-is so rate evaluation
      # can still fall back through downstream safeguards and defaults.
      if inflation_like && auto_fetch_inflation && inflation_provider.blank? && Setting.inflation_import_enabled_effective
        self.auto_fetch_inflation = false
      end
    end

    def deflation_floor_applies?
      product_code&.start_with?("pl_")
    end

    def inflation_provider_key
      inflation_provider.presence || Bond::InflationProvider.default_provider_for(
        account: account,
        bond: bond,
        lot: self,
        product_code: product_code
      )
    end

    def inflation_rate_record_for(on:, allow_import: true)
      cache_key = [ inflation_provider_key, on.to_date, cpi_lag_months.to_i, allow_import ]
      cache = Thread.current[:bond_inflation_record_cache]
      return cache[cache_key] if cache&.key?(cache_key)

      Bond::InflationProvider.record_for_date(
        provider: inflation_provider_key,
        date: on,
        lag_months: cpi_lag_months.to_i,
        allow_import:
      ).tap do |result|
        cache[cache_key] = result if cache
      end
    end

    def inflation_source_label
      inflation_provider_key
    end

    def create_settlement_entry!(settlement_date:, net_value:, tax_withheld_amount:, gross_value:)
      subtype_label = Bond.long_subtype_label_for(subtype) || Bond.display_name.singularize
      interest_amount = (gross_value - amount.to_d).round(4)

      settlement_entry = account.entries.create!(
        date: settlement_date,
        name: I18n.t("bond_lots.activity.maturity_settlement_name", subtype: subtype_label),
        notes: settlement_notes(
          purchase_amount: amount.to_d,
          interest_amount: interest_amount,
          tax_withheld_amount: tax_withheld_amount
        ),
        amount: -net_value,
        currency: account.currency,
        entryable: Transaction.new(
          kind: :funds_movement,
          extra: {
            "bond_lot_id" => id,
            "bond_lot_settlement" => true,
            "bond_subtype" => subtype,
            "bond_maturity_date" => maturity_date,
            "bond_settlement_gross" => gross_value,
            "bond_settlement_net" => net_value,
            "bond_settlement_tax_withheld" => tax_withheld_amount,
            "bond_settlement_tax_strategy" => tax_strategy,
            "bond_settlement_tax_rate" => settlement_tax_rate_percent
          }
        )
      )

      settlement_entry.lock_saved_attributes!
      settlement_entry.mark_user_modified!
    end

    def create_reinvestment_lot!(settlement_date:, net_value:)
      nominal = nominal_per_unit.presence || 100
      replacement_units = inflation_linked? ? (net_value.to_d / nominal.to_d).floor : nil
      replacement_amount = if inflation_linked?
        replacement_units.to_d * nominal.to_d
      else
        net_value.to_d
      end

      return if replacement_amount <= 0

      replacement_lot = bond.bond_lots.new(
        purchased_on: settlement_date,
        issue_date: inflation_linked? ? settlement_date : nil,
        amount: replacement_amount,
        product_code: product_code,
        units: replacement_units,
        nominal_per_unit: inflation_linked? ? nominal : nil,
        subtype: subtype,
        interest_rate: inflation_linked? ? nil : interest_rate,
        rate_type: inflation_linked? ? nil : rate_type,
        coupon_frequency: inflation_linked? ? nil : coupon_frequency,
        first_period_rate: nil,
        inflation_margin: nil,
        inflation_rate_assumption: inflation_rate_assumption,
        inflation_provider: inflation_provider,
        cpi_lag_months: cpi_lag_months,
        auto_fetch_inflation: auto_fetch_inflation,
        auto_close_on_maturity: auto_close_on_maturity,
        early_redemption_fee: early_redemption_fee,
        tax_strategy: tax_strategy,
        tax_rate: tax_rate,
        requires_rate_review: true
      )
      replacement_lot.save!
      replacement_lot.create_purchase_entry!(auto_purchased: true, requires_rate_review: true)
    end

    def subtype_label
      Bond.long_subtype_label_for(canonical_subtype) || Bond.display_name.singularize
    end

    def canonical_subtype
      Bond::LEGACY_SUBTYPE_ALIASES.fetch(subtype.to_s, subtype)
    end

    def purchase_entry_extra(auto_purchased: false, requires_rate_review: false)
      {
        "bond_lot_id" => id,
        "bond_subtype" => subtype,
        "bond_term_months" => term_months,
        "bond_interest_rate" => interest_rate
      }.tap do |extra|
        extra["bond_auto_purchased"] = true if auto_purchased
        extra["bond_requires_rate_review"] = true if requires_rate_review
      end
    end

    def settlement_notes(purchase_amount:, interest_amount:, tax_withheld_amount:)
      formatted_purchase_amount = Money.new(purchase_amount, account.currency).format
      formatted_interest_amount = Money.new(interest_amount, account.currency).format

      if tax_withheld_amount.to_d.positive?
        I18n.t(
          "bond_lots.activity.maturity_settlement_notes_with_tax",
          purchase_amount: formatted_purchase_amount,
          interest_amount: formatted_interest_amount,
          tax_withheld_amount: Money.new(tax_withheld_amount, account.currency).format
        )
      else
        I18n.t(
          "bond_lots.activity.maturity_settlement_notes_without_tax",
          purchase_amount: formatted_purchase_amount,
          interest_amount: formatted_interest_amount
        )
      end
    end

    def derive_amount_from_units
      return if units.blank? || nominal_per_unit.blank?

      expected = units.to_d * nominal_per_unit.to_d
      self.amount = expected if amount.blank? || inflation_linked? || amount.to_d != expected
    end

    def normalize_tax_settings
      if bond&.tax_exempt_wrapper?
        self.tax_strategy = "exempt"
        self.tax_rate = 0
        return
      end

      self.tax_strategy = "standard" if tax_strategy.blank?
      self.tax_rate = if tax_strategy == "exempt"
        0
      else
        tax_rate.presence || DEFAULT_TAX_RATE_PERCENT
      end
    end

    def clear_rate_review_flag
      return unless requires_rate_review?

      review_date = [ Date.current, maturity_date ].compact.min
      self.requires_rate_review = false if rates_present_for_review?(on: review_date) && review_date.present? && rates_resolvable_through?(date: review_date, allow_import: false)
    end

    def rates_present_for_review?(on: purchased_on || Date.current)
      if inflation_linked?
        (!needs_first_period_rate?(on:) || first_period_rate.present?) && inflation_margin.present?
      else
        interest_rate.present?
      end
    end

    def validate_issue_date_not_after_purchased_on
      return if issue_date.blank? || purchased_on.blank?
      errors.add(:issue_date, "cannot be after purchase date") if issue_date > purchased_on
    end

    def validate_maturity_date_not_before_purchased_on
      return if purchased_on.blank? || maturity_date.blank?
      errors.add(:maturity_date, "must be on or after purchase date") if maturity_date < purchased_on
    end

    def assign_maturity_date_from_term
      return if term_months.blank?
      base_date = (issue_date.present? && (purchased_on.blank? || issue_date < purchased_on)) ? issue_date : purchased_on
      return if base_date.blank?

      return unless maturity_date.blank? || will_save_change_to_term_months? || will_save_change_to_issue_date? || will_save_change_to_purchased_on?

      self.maturity_date = base_date + term_months.months
    end

    def needs_inflation_backfill?
      inflation_linked? && auto_fetch_inflation? && purchased_on.present? && Bond::InflationProvider.automatic_import_enabled?(inflation_provider_key)
    end

    def should_enqueue_inflation_backfill?
      return false unless needs_inflation_backfill?
      saved_change_to_purchased_on? ||
        saved_change_to_issue_date? ||
        saved_change_to_cpi_lag_months? ||
        saved_change_to_inflation_provider? ||
        saved_change_to_auto_fetch_inflation? ||
        saved_change_to_subtype?
    end

    def should_settle_if_already_matured?
      open? && auto_close_on_maturity? && maturity_date.present? && maturity_date <= Date.current && entry_id.present?
    end

    def settle_if_already_matured!
      settle_if_matured!(on: Date.current)
    end

    def should_auto_buy_new_issue?(net_value:)
      return false unless bond&.auto_buy_new_issues?
      return false unless bond&.tax_exempt_wrapper?
      return false unless inflation_linked?

      nominal = nominal_per_unit.presence || 100
      (net_value.to_d / nominal.to_d).floor.positive?
    end

    def enqueue_inflation_backfill
      start_year = [ purchased_on.year - 1, Date.current.year - 20 ].max
      end_year = Date.current.year

      # Current year won't have all 12 months yet — only expect up to the current month.
      today = Date.current
      required_months = (start_year..end_year).sum { |y| y == today.year ? today.month : 12 }

      return if required_months <= 0

      provider = inflation_provider_key
      return unless Bond::InflationProvider.automatic_import_enabled?(provider)

      existing_count =
        if provider == "gus_sdp"
          GusInflationRate.where(year: start_year..end_year).count
        else
          InflationRate.where(source: provider, year: start_year..end_year).count
        end

      return if existing_count >= required_months

      ImportInflationRatesJob.perform_later(start_year:, end_year:, providers: [ provider ])
    end

    # Returns false if any annual rate period between purchased_on and date cannot be resolved.
    # Used by settle_if_matured! to abort settlement when GUS data or rates are missing.
    # Also used by needs_rate_review class method to identify lots with unresolvable rates.
    def rates_resolvable_through?(date:, allow_import: true)
      return true unless purchased_on.present?

      issue_base = anniversary_issue_base
      cursor = purchased_on

      while cursor < date
        return false if annual_rate_for(on: cursor, allow_import:).blank?

        next_anniversary, _ = anniversary_boundaries(cursor:, issue_base:)
        cursor = [ next_anniversary, date ].min
      end

      true
    end
    public :rates_resolvable_through?
end
