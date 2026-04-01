class BondLot < ApplicationRecord
  belongs_to :bond
  belongs_to :entry, optional: true

  TAX_STRATEGIES = %w[standard reduced exempt].freeze

  scope :open, -> { where(closed_on: nil) }
  scope :needs_rate_review, -> { open.where(requires_rate_review: true) }

  before_validation :inherit_defaults_from_bond
  before_validation :apply_product_defaults
  before_validation :assign_maturity_date_from_term
  before_validation :derive_amount_from_units
  before_validation :normalize_auto_fetch_inflation
  before_validation :apply_bond_tax_wrapper
  before_validation :normalize_tax_settings
  before_validation :clear_rate_review_flag

  after_commit :enqueue_inflation_backfill, on: %i[create update], if: :needs_inflation_backfill?

  validates :purchased_on, :amount, :subtype, presence: true
  validates :auto_fetch_inflation, inclusion: { in: [ true, false ] }
  validates :amount, numericality: { greater_than: 0 }
  validates :term_months, presence: true, unless: :inflation_linked?
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
  validates :rate_type, inclusion: { in: Bond::RATE_TYPES }, allow_nil: true
  validates :coupon_frequency, inclusion: { in: Bond::COUPON_FREQUENCIES }, allow_nil: true
  validates :tax_strategy, inclusion: { in: TAX_STRATEGIES }
  validates :tax_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  with_options if: :inflation_linked? do
    validates :issue_date, presence: true
    validates :units, presence: true
    validates :nominal_per_unit, presence: true
    validates :first_period_rate, presence: true, unless: :requires_rate_review?
    validates :inflation_margin, presence: true, unless: :requires_rate_review?
    validates :cpi_lag_months, presence: true
    validates :inflation_rate_assumption, presence: true, unless: -> { auto_fetch_inflation? || requires_rate_review? }
  end

  with_options unless: :inflation_linked? do
    validates :interest_rate, presence: true, unless: :requires_rate_review?
    validates :rate_type, presence: true, unless: :requires_rate_review?
    validates :coupon_frequency, presence: true, unless: :requires_rate_review?
  end

  def account
    bond.account
  end

  def open?
    closed_on.blank?
  end

  def matured?(on: Date.current)
    maturity_date.present? && on >= maturity_date
  end

  def inflation_linked?
    subtype.in?(%w[eod rod])
  end

  def auto_fetch_inflation?
    inflation_linked? && auto_fetch_inflation && Setting.gus_inflation_import_enabled_effective
  end

  def estimated_current_value(on: Date.current)
    principal = amount.to_d
    return principal if principal.zero? || purchased_on.blank?

    period_end = [ on, maturity_date ].compact.min
    return principal if period_end.blank? || period_end <= purchased_on

    value = principal
    cursor = purchased_on

    while cursor < period_end
      next_cursor = [ cursor + 1.year, period_end ].min
      days_in_step = [ (next_cursor - cursor).to_i, 0 ].max
      break if days_in_step.zero?

      annual_rate_decimal = annual_rate_for(on: cursor)
      break if annual_rate_decimal.blank?

      days_in_year = [ (cursor + 1.year - cursor).to_i, 1 ].max

      if next_cursor == cursor + 1.year
        value *= (1 + annual_rate_decimal)
      else
        value *= (1 + annual_rate_decimal * (days_in_step.to_d / days_in_year))
      end

      cursor = next_cursor
    end

    value
  end

  def total_return_amount(on: Date.current)
    estimated_current_value(on:) - amount.to_d
  end

  def total_return_percent(on: Date.current)
    principal = amount.to_d
    return 0 if principal.zero?

    (total_return_amount(on:) / principal) * 100
  end

  def projected_total_return_amount
    maturity = maturity_date || (purchased_on + term_months.to_i.months if term_months.present?)
    return 0.to_d if maturity.blank?

    estimated_current_value(on: maturity) - amount.to_d
  end

  def projected_total_return_percent
    principal = amount.to_d
    return 0 if principal.zero?

    (projected_total_return_amount / principal) * 100
  end

  def current_rate_percent(on: Date.current)
    annual_rate_for(on:)&.*(100)
  end

  def current_inflation_component_percent(on: Date.current)
    return nil unless inflation_linked?

    inflation_snapshot_for(on:)[:inflation_component_percent]
  end

  def current_inflation_source(on: Date.current)
    return nil unless inflation_linked?

    inflation_snapshot_for(on:)[:source]
  end

  def current_margin_percent
    return nil unless inflation_linked?

    inflation_margin.presence&.to_d
  end

  def current_inflation_indicator_id
    return nil unless inflation_linked? && auto_fetch_inflation?

    ENV["GUS_SDP_CPI_INDICATOR_ID"].presence || Provider::GusSdp::DEFAULT_CPI_INDICATOR_ID
  end

  def settlement_tax_rate_percent
    return 0.to_d if tax_strategy == "exempt"

    rate = tax_rate.presence || 19
    rate.to_d
  end

  def settle_if_matured!(on: Date.current)
    # Lock the row to prevent concurrent settlements.
    with_lock do
      return false unless auto_close_on_maturity?
      return false unless open?
      return false unless matured?(on:)

      settlement_date = [ on, maturity_date ].compact.min
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

      account.sync_later(window_start_date: settlement_date)
      true
    end
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

    while cursor < history_end
      next_cursor = [ cursor + 1.year, history_end ].min
      days_in_step = [ (next_cursor - cursor).to_i, 0 ].max
      break if days_in_step.zero?

      rate_context = rate_context_for(on: cursor)
      annual_rate_decimal = rate_context[:annual_rate_decimal]
      break if annual_rate_decimal.blank?

      days_in_year = [ (cursor + 1.year - cursor).to_i, 1 ].max
      full_year_capitalization = (next_cursor == cursor + 1.year)
      interest_earned = if full_year_capitalization
        opening_balance * annual_rate_decimal
      else
        opening_balance * annual_rate_decimal * (days_in_step.to_d / days_in_year)
      end

      closing_balance = opening_balance + interest_earned

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
      def rate_context_for(on:)
        if inflation_linked?
          inflation_linked_rate_context(on:)
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

      def annual_rate_for(on:)
        rate_context_for(on:)[:annual_rate_decimal]
      end

      def inflation_linked_rate_context(on:)
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

        # Anniversary-based calculation avoids leap year issues with simple 365-day division.
        years_elapsed = 0
        current_check_date = purchased_on
        until current_check_date > on
          current_check_date = purchased_on + (years_elapsed + 1).years
          break if current_check_date > on
          years_elapsed += 1
        end

        if years_elapsed <= 0
          {
            annual_rate_decimal: first_period_rate&.to_d&./(100),
            inflation_component_percent: nil,
            margin_component_percent: nil,
            inflation_source: "first_period",
            inflation_reference_on: nil,
            inflation_indicator_id: nil
          }
        else
          inflation_snapshot = inflation_snapshot_for(on:)
          inflation_component = inflation_snapshot[:inflation_component_percent]
          margin_component = inflation_margin&.to_d || 0.to_d

          # Guard against nil margin in requires_rate_review lots.
          return { annual_rate_decimal: nil } if inflation_component.nil? && margin_component.zero?

          {
            annual_rate_decimal: ((inflation_component || 0.to_d) + margin_component) / 100,
            inflation_component_percent: inflation_component,
            margin_component_percent: margin_component,
            inflation_source: inflation_snapshot[:source],
            inflation_reference_on: inflation_snapshot[:reference_on],
            inflation_indicator_id: inflation_snapshot[:indicator_id]
          }
        end
      end

      def inflation_snapshot_for(on:)
        if auto_fetch_inflation?
          source_record = GusInflationRate.for_date(date: on, lag_months: cpi_lag_months.to_i)
          if source_record.present?
            return {
              inflation_component_percent: source_record.rate_yoy.to_d - 100,
              source: "gus",
              reference_on: Date.new(source_record.year, source_record.month, 1),
              indicator_id: current_inflation_indicator_id
            }
          end
        end

        {
          inflation_component_percent: inflation_rate_assumption.to_d,
          source: "manual",
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

      def apply_product_defaults
        defaults = Bond::PRODUCT_DEFAULTS[subtype]
        return if defaults.blank?

        self.term_months = defaults[:term_months]
        self.rate_type ||= defaults[:rate_type]
        self.coupon_frequency ||= defaults[:coupon_frequency]
        self.cpi_lag_months ||= defaults[:cpi_lag_months]
        self.nominal_per_unit ||= 100
        self.issue_date ||= purchased_on
        self.auto_fetch_inflation = true if auto_fetch_inflation.nil?
      end

      def normalize_auto_fetch_inflation
        self.auto_fetch_inflation = true if auto_fetch_inflation.nil?
        return if inflation_linked?

        self.auto_fetch_inflation = false
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

        replacement_lot = bond.bond_lots.create!(
          purchased_on: settlement_date,
          issue_date: inflation_linked? ? settlement_date : nil,
          amount: replacement_amount,
          units: replacement_units,
          nominal_per_unit: inflation_linked? ? nominal : nil,
          term_months: inflation_linked? ? nil : term_months,
          subtype: subtype,
          interest_rate: inflation_linked? ? nil : nil,
          rate_type: inflation_linked? ? nil : rate_type,
          coupon_frequency: inflation_linked? ? nil : coupon_frequency,
          first_period_rate: nil,
          inflation_margin: nil,
          inflation_rate_assumption: inflation_rate_assumption,
          cpi_lag_months: cpi_lag_months,
          auto_fetch_inflation: auto_fetch_inflation,
          auto_close_on_maturity: auto_close_on_maturity,
          early_redemption_fee: early_redemption_fee,
          tax_strategy: tax_strategy,
          tax_rate: tax_rate,
          requires_rate_review: true
        )

        replacement_lot.update!(entry: create_purchase_entry_for!(replacement_lot))
      end

      def create_purchase_entry_for!(replacement_lot)
        subtype_label = Bond.long_subtype_label_for(replacement_lot.subtype) || Bond.display_name.singularize

        entry = account.entries.create!(
          date: replacement_lot.purchased_on,
          name: I18n.t("bond_lots.activity.purchase_name", subtype: subtype_label),
          amount: replacement_lot.amount,
          currency: account.currency,
          entryable: Transaction.new(
            kind: :funds_movement,
            extra: {
              "bond_lot_id" => replacement_lot.id,
              "bond_subtype" => replacement_lot.subtype,
              "bond_term_months" => replacement_lot.term_months,
              "bond_interest_rate" => replacement_lot.interest_rate,
              "bond_auto_purchased" => true,
              "bond_requires_rate_review" => true
            }
          )
        )

        entry.lock_saved_attributes!
        entry.mark_user_modified!
        entry
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
        return if amount.present?
        return if units.blank? || nominal_per_unit.blank?

        self.amount = units.to_d * nominal_per_unit.to_d
      end

      def normalize_tax_settings
        return self.tax_rate = 0 if apply_tax_exempt_wrapper!

        self.tax_strategy = "standard" if tax_strategy.blank?
        self.tax_rate = if tax_strategy == "exempt"
          0
        else
          tax_rate.presence || 19
        end
      end

      def apply_bond_tax_wrapper
        return unless bond&.tax_exempt_wrapper?

        self.tax_strategy = "exempt"
        self.tax_rate = 0
      end

      def apply_tax_exempt_wrapper!
        return false unless bond&.tax_exempt_wrapper?

        self.tax_strategy = "exempt"
        true
      end

      def clear_rate_review_flag
        return unless requires_rate_review?

        self.requires_rate_review = false if rates_present_for_review?
      end

      def rates_present_for_review?
        if inflation_linked?
          first_period_rate.present? && inflation_margin.present?
        else
          interest_rate.present?
        end
      end

      def assign_maturity_date_from_term
        return if purchased_on.blank? || term_months.blank? || maturity_date.present?
        self.maturity_date = purchased_on + term_months.months
      end

      def needs_inflation_backfill?
        inflation_linked? && auto_fetch_inflation? && purchased_on.present?
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

        ImportGusInflationRatesJob.perform_later(start_year:, end_year:)
      end
end
