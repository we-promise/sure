# Weight conversion and formatting. Weights are stored in grams (BigDecimal);
# the exact international troy ounce definition is used for conversion.
module Commodity::Weight
  GRAMS_PER_TROY_OUNCE = BigDecimal("31.1034768")
  UNITS = %w[g ozt].freeze

  module_function

  def to_grams(value, unit)
    value = BigDecimal(value.to_s)
    unit.to_s == "ozt" ? value * GRAMS_PER_TROY_OUNCE : value
  end

  def from_grams(grams, unit)
    grams = BigDecimal(grams.to_s)
    unit.to_s == "ozt" ? grams / GRAMS_PER_TROY_OUNCE : grams
  end

  # Grams to 2 decimals (4 below 1 g); troy ounces to 3 decimals (4 below 1 ozt).
  def format(grams, unit)
    unit = UNITS.include?(unit.to_s) ? unit.to_s : "g"
    value = from_grams(grams, unit)
    precision = if unit == "g"
      value.abs < 1 ? 4 : 2
    else
      value.abs < 1 ? 4 : 3
    end

    "#{ActiveSupport::NumberHelper.number_to_rounded(value, precision: precision, delimiter: ",")} #{I18n.t("commodities.units.#{unit}")}"
  end
end
