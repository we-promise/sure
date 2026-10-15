# Commodities are their own asset class (alongside cash, investments, crypto and
# property). They are deliberately not modelled as securities: physical items
# live in Commodity::Item, prices in Commodity::Price, and the account balance
# is computed by Balance::CommodityCalculator from inventory x daily price.
class Commodity < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "precious_metal" => { short: "Precious metals", long: "Precious metals" }
  }.freeze

  DEFAULT_ACCOUNT_NAME = "Commodities"

  # One configured commodity (e.g. gold). Defined in config/commodities.yml.
  Metal = Data.define(:code, :key, :subclass, :enabled, :yahoo_symbol, :metal_price_api_symbol, :default_fineness) do
    def name
      I18n.t("commodities.metals.#{key}", default: key.to_s.titleize)
    end

    def fineness_for(form)
      default_fineness.fetch(form.to_s, default_fineness["other"])
    end
  end

  CATALOG = Rails.application.config_for(:commodities).flat_map do |subclass, entries|
    entries.map do |code, attrs|
      Metal.new(
        code: code.to_s,
        key: attrs[:key].to_s,
        subclass: subclass.to_s,
        enabled: attrs[:enabled] == true,
        yahoo_symbol: attrs[:yahoo_symbol],
        metal_price_api_symbol: attrs[:metal_price_api_symbol],
        default_fineness: attrs[:default_fineness].to_h { |form, value| [ form.to_s, BigDecimal(value.to_s) ] }.freeze
      )
    end
  end.freeze

  attribute :subtype, :string, default: "precious_metal"

  class << self
    def color
      "#CA8A04"
    end

    def icon
      "coins"
    end

    def classification
      "asset"
    end

    # Enabled commodities, in configuration order.
    def metals
      CATALOG.select(&:enabled)
    end

    def metal(code)
      CATALOG.find { |m| m.code == code.to_s }
    end
  end

  def balance_display_name
    "melt value"
  end
end
