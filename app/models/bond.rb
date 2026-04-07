class Bond < ApplicationRecord
  include Accountable

  has_many :bond_lots, dependent: :destroy

  TAX_WRAPPERS = {
    "none" => { short: "Standard", long: "Standard" },
    "ike" => { short: "IKE", long: "IKE" },
    "ikze" => { short: "IKZE", long: "IKZE" }
  }.freeze

  before_validation :assign_maturity_date_from_term
  before_validation :normalize_tax_wrapper_settings
  before_validation :normalize_legacy_subtype

  SUBTYPES = {
    "zero_coupon" => { short: "Zero-Coupon", long: "Zero-Coupon Bill" },
    "fixed_coupon" => { short: "Fixed", long: "Fixed Coupon Bond" },
    "inflation_linked" => { short: "ILB", long: "Inflation-Linked Bond" },
    "savings" => { short: "Savings", long: "Savings Bond" },
    "other" => { short: "Other", long: "Other Bond" }
  }.freeze

  LEGACY_SUBTYPE_ALIASES = {
    "eod" => "inflation_linked",
    "rod" => "inflation_linked",
    "other_bond" => "other"
  }.freeze

  INFLATION_LINKED_SUBTYPES = %w[inflation_linked].freeze

  PRODUCT_DEFAULTS = {
    "us_t_bill_4w" => {
      subtype: "zero_coupon",
      term_months: 1,
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    },
    "us_t_bill_52w" => {
      subtype: "zero_coupon",
      term_months: 12,
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    },
    "us_t_note_2y" => {
      subtype: "fixed_coupon",
      term_months: 24,
      rate_type: "fixed",
      coupon_frequency: "semi_annual"
    },
    "us_t_note_10y" => {
      subtype: "fixed_coupon",
      term_months: 120,
      rate_type: "fixed",
      coupon_frequency: "semi_annual"
    },
    "us_tips_10y" => {
      subtype: "inflation_linked",
      term_months: 120,
      rate_type: "variable",
      coupon_frequency: "semi_annual",
      cpi_lag_months: 3,
      inflation_provider: "us_bls"
    },
    "us_i_bond" => {
      subtype: "savings",
      term_months: 120,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    },
    "es_letra_3m" => {
      subtype: "zero_coupon",
      term_months: 3,
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    },
    "es_letra_6m" => {
      subtype: "zero_coupon",
      term_months: 6,
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    },
    "es_letra_12m" => {
      subtype: "zero_coupon",
      term_months: 12,
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    },
    "pl_eod" => {
      subtype: "inflation_linked",
      term_months: 120,
      rate_type: "variable",
      coupon_frequency: "at_maturity",
      cpi_lag_months: 2
    },
    "pl_rod" => {
      subtype: "inflation_linked",
      term_months: 144,
      rate_type: "variable",
      coupon_frequency: "at_maturity",
      cpi_lag_months: 2
    }
  }.freeze

  PRODUCT_LABELS = {
    "us_t_bill_4w" => "US T-Bill (4 weeks)",
    "us_t_bill_52w" => "US T-Bill (52 weeks)",
    "us_t_note_2y" => "US T-Note (2 years)",
    "us_t_note_10y" => "US T-Note (10 years)",
    "us_tips_10y" => "US TIPS (10 years)",
    "us_i_bond" => "US I Bond",
    "es_letra_3m" => "ES Letra del Tesoro (3 months)",
    "es_letra_6m" => "ES Letra del Tesoro (6 months)",
    "es_letra_12m" => "ES Letra del Tesoro (12 months)",
    "pl_eod" => "PL EOD (10 years)",
    "pl_rod" => "PL ROD (12 years)"
  }.freeze

  RATE_TYPES = %w[fixed variable].freeze
  COUPON_FREQUENCIES = %w[monthly quarterly semi_annual annual at_maturity].freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_nil: true
  validates :rate_type, inclusion: { in: RATE_TYPES }, allow_nil: true
  validates :coupon_frequency, inclusion: { in: COUPON_FREQUENCIES }, allow_nil: true
  validates :tax_wrapper, inclusion: { in: TAX_WRAPPERS.keys }

  def original_balance
    total = bond_lots.sum(:amount)
    return Money.new(total, account.currency) if total.positive?

    fallback = account.first_valuation_amount
    Money.new(fallback.amount, fallback.currency)
  end

  def holdings_balance
    Money.new(bond_lots.open.sum(:amount), account.currency)
  end

  def settle_matured_lots!(on: Date.current)
    bond_lots.open.find_each do |lot|
      lot.settle_if_matured!(on:)
    end
  end

  def tax_exempt_wrapper?
    tax_wrapper.in?(%w[ike ikze])
  end

  def default_tax_strategy
    tax_exempt_wrapper? ? "exempt" : "standard"
  end

  def pending_rate_review_lots
    bond_lots.open.where(requires_rate_review: true)
  end

  def wrapper_label(format: :short)
    label_type = format == :long ? :long : :short
    TAX_WRAPPERS.dig(tax_wrapper, label_type)
  end

  class << self
    def color
      "#2BBB0E"
    end

    def icon
      "badge-percent"
    end

    def classification
      "asset"
    end

    def display_name
      I18n.t("accounts.sidebar.types.bond", default: super)
    end

    def product_options_for_select
      PRODUCT_DEFAULTS.keys.map { |code| [ PRODUCT_LABELS.fetch(code, code.humanize), code ] }
    end
  end

  def inflation_linked?
    subtype&.in?(INFLATION_LINKED_SUBTYPES) || false
  end

  private
    def normalize_legacy_subtype
      self.subtype = LEGACY_SUBTYPE_ALIASES.fetch(subtype, subtype) if subtype.present?
    end

    def normalize_tax_wrapper_settings
      self.tax_wrapper = "none" if tax_wrapper.blank?
      self.auto_buy_new_issues = false unless tax_exempt_wrapper?
    end

    def assign_maturity_date_from_term
      return if term_months.blank? || maturity_date.present?

      self.maturity_date = Date.current + term_months.months
    end
end
