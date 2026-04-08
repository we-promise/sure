class IndianGoldInvestment < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "physical_gold" => { short: "Physical Gold", long: "Physical Gold (Jewelry/Bars/Coins)", region: "in", tax_treatment: :taxable },
    "gold_etf" => { short: "Gold ETF", long: "Gold Exchange-Traded Fund", region: "in", tax_treatment: :taxable },
    "sgb" => { short: "SGB", long: "Sovereign Gold Bond", region: "in", tax_treatment: :tax_exempt },
    "gold_mutual_fund" => { short: "Gold MF", long: "Gold Mutual Fund", region: "in", tax_treatment: :taxable },
    "digital_gold" => { short: "Digital Gold", long: "Digital Gold (Online/Gold Locker)", region: "in", tax_treatment: :taxable }
  }.freeze

  attribute :quantity_grams, :decimal, precision: 10, scale: 4
  attribute :purity, :string
  attribute :purchase_price_per_gram, :decimal, precision: 19, scale: 2
  attribute :weight_unit, :string, default: "grams"

  class << self
    def icon
      "gem"
    end

    def color
      "#D97706"
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

  def balance_display_name
    "current value"
  end

  def opening_balance_display_name
    "purchase price"
  end

  def trend
    Trend.new(current: account.balance_money, previous: purchase_price_per_gram.to_d * quantity_grams.to_d)
  end

  def quantity_display
    "#{quantity_grams} #{weight_unit}" if quantity_grams.present?
  end

  def purity_display
    purity if purity.present?
  end

  def total_purchase_value
    purchase_price_per_gram.to_d * quantity_grams.to_d if purchase_price_per_gram.present? && quantity_grams.present?
  end
end
