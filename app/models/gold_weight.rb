module GoldWeight
  TROY_OUNCE_GRAMS = BigDecimal("31.1034768")

  def self.in_grams(weight, unit)
    return BigDecimal(0) if weight.blank?

    case unit
    when "gram" then weight.to_d
    when "kilogram" then weight.to_d * 1_000
    when "troy_ounce" then weight.to_d * TROY_OUNCE_GRAMS
    else BigDecimal(0)
    end
  end
end
