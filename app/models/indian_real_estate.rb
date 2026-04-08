class IndianRealEstate < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "apartment" => { short: "Apartment", long: "Apartment/Flat", region: "in", tax_treatment: :taxable },
    "plot" => { short: "Plot", long: "Land/Plot", region: "in", tax_treatment: :taxable },
    "commercial_property" => { short: "Commercial", long: "Commercial Property", region: "in", tax_treatment: :taxable },
    "rented_property" => { short: "Rented", long: "Rented Property", region: "in", tax_treatment: :taxable },
    "under_construction" => { short: "Under Construction", long: "Property Under Construction", region: "in", tax_treatment: :taxable },
    "agricultural_land" => { short: "Agri Land", long: "Agricultural Land", region: "in", tax_treatment: :tax_exempt }
  }.freeze

  has_one :address, as: :addressable, dependent: :destroy

  accepts_nested_attributes_for :address

  attribute :area_unit, :string, default: "sqft"
  attribute :area_value, :decimal, precision: 19, scale: 4
  attribute :registration_number, :string
  attribute :property_type_classification, :string

  class << self
    def icon
      "building"
    end

    def color
      "#059669"
    end

    def classification
      "asset"
    end

    def region_label_for(region)
      I18n.t("accounts.subtype_regions.#{region || 'generic'}")
    end

    def subtypes_grouped_for_select(currency: nil)
      grouped = SUBTYPES.group_by { |_, v| v[:region] }
      region_label = region_label_for("in")
      [ [ region_label, SUBTYPES.map { |k, v| [ v[:long], k ] } ] ]
    end
  end

  def tax_treatment
    SUBTYPES.dig(subtype, :tax_treatment) || :taxable
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
    "purchase price"
  end

  private
    def first_valuation_amount
      account.entries.valuations.order(:date).first&.amount_money || account.balance_money
    end
end
