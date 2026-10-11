class Property < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "single_family_home" => { short: "Single Family Home", long: "Single Family Home" },
    "multi_family_home" => { short: "Multi-Family Home", long: "Multi-Family Home" },
    "condominium" => { short: "Condo", long: "Condominium" },
    "townhouse" => { short: "Townhouse", long: "Townhouse" },
    "investment_property" => { short: "Investment Property", long: "Investment Property" },
    "second_home" => { short: "Second Home", long: "Second Home" },
    "apartment" => { short: "Apartment", long: "Apartment" },
    "plot" => { short: "Plot", long: "Plot / Land" },
    "commercial" => { short: "Commercial", long: "Commercial Property" },
    "agri_land" => { short: "Agri Land", long: "Agricultural Land" }
  }.freeze

  has_one :address, as: :addressable, dependent: :destroy

  accepts_nested_attributes_for :address

  attribute :area_unit, :string, default: "sqft"

  class << self
    def icon
      "home"
    end

    def color
      "#06AED4"
    end

    def classification
      "asset"
    end
  end

  def area
    Measurement.new(area_value, area_unit) if area_value.present?
  end

  def purchase_price
    first_valuation_amount
  end

  def trend
    Trend.new(current: account.balance_money, previous: first_valuation_amount)
  end

  def balance_display_name
    "market value"
  end

  def opening_balance_display_name
    "original purchase price"
  end

  # Balance updates are recorded as "Manual value update" reconciliations;
  # rename the one an AVM provider just wrote so the activity feed shows
  # where the value came from. Account::ReconciliationManager resets the name
  # on any later write to that day's entry.
  def name_avm_valuation!(date = Date.current)
    return if avm_provider.blank?

    entry = account.entries.valuations.find_by(date: date)
    return unless entry&.entryable&.reconciliation?

    provider_name = I18n.t("properties.avm_providers.#{avm_provider}", default: avm_provider.titleize)
    entry.update!(name: I18n.t("providers.property_valuation.entry_name", provider: provider_name))
  end

  private
    def first_valuation_amount
      account.entries.valuations.order(:date).first&.amount_money || account.balance_money
    end
end
