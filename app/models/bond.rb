class Bond < ApplicationRecord
  include Accountable

  has_many :bond_lots, dependent: :destroy

  TAX_WRAPPERS = {
    "none" => { short: "Standard", long: "Standard" },
    "ike" => { short: "IKE", long: "IKE" },
    "ikze" => { short: "IKZE", long: "IKZE" }
  }.freeze

  before_validation :assign_maturity_date_from_term
  before_validation :apply_subtype_defaults
  before_validation :normalize_tax_wrapper_settings

  SUBTYPES = {
    "eod" => { short: "EOD", long: "10-year Treasury Savings Bond" },
    "rod" => { short: "ROD", long: "12-year Family Treasury Savings Bond" },
    "other_bond" => { short: "Other", long: "Other Bond" }
  }.freeze

  INFLATION_LINKED_SUBTYPES = %w[eod rod].freeze

  PRODUCT_DEFAULTS = {
    "eod" => {
      term_months: 120,
      rate_type: "variable",
      coupon_frequency: "at_maturity",
      cpi_lag_months: 2
    },
    "rod" => {
      term_months: 144,
      rate_type: "variable",
      coupon_frequency: "at_maturity",
      cpi_lag_months: 2
    }
  }.freeze

  RATE_TYPES = %w[fixed variable].freeze
  COUPON_FREQUENCIES = %w[monthly quarterly semi_annual annual at_maturity].freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_nil: true
  validates :tax_wrapper, inclusion: { in: TAX_WRAPPERS.keys }

  def original_balance
    principal_amount = if bond_lots.exists?
      bond_lots.sum(:amount)
    else
      account.first_valuation_amount
    end

    Money.new(principal_amount, account.currency)
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
  end

  def inflation_linked?
    subtype.in?(INFLATION_LINKED_SUBTYPES)
  end

  private
    def normalize_tax_wrapper_settings
      self.tax_wrapper = "none" if tax_wrapper.blank?
      self.auto_buy_new_issues = false unless tax_exempt_wrapper?
    end

    def apply_subtype_defaults
      defaults = PRODUCT_DEFAULTS[subtype]
      return if defaults.blank?

      self.term_months ||= defaults[:term_months]
      self.rate_type ||= defaults[:rate_type]
      self.coupon_frequency ||= defaults[:coupon_frequency]
    end

    def assign_maturity_date_from_term
      return if term_months.blank? || maturity_date.present?

      self.maturity_date = Time.zone.today + term_months.months
    end
end
