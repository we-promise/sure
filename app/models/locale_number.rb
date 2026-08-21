# Parses and formats decimals the way users type them (comma or period).
class LocaleNumber
  class << self
    def parse(value)
      return value if value.is_a?(Numeric)
      return if value.blank?

      cleaned = value.to_s.gsub(/[[:space:]]/, "")
      return BigDecimal(cleaned) if cleaned.match?(/\A-?\d+\z/)

      last_comma = cleaned.rindex(",")
      last_dot = cleaned.rindex(".")

      normalized = if last_comma && last_dot
        if last_comma > last_dot
          cleaned.delete(".").tr(",", ".")
        else
          cleaned.delete(",")
        end
      elsif last_comma
        digits_after = cleaned.length - last_comma - 1
        if last_dot.nil? && digits_after == 3
          cleaned.delete(",")
        else
          cleaned.tr(",", ".")
        end
      else
        cleaned
      end

      BigDecimal(normalized)
    rescue ArgumentError
      value
    end

    def format(value, precision: 2)
      return if value.nil? || value == ""

      ActiveSupport::NumberHelper.number_to_rounded(
        value,
        precision: precision,
        delimiter: "",
        separator: I18n.t("number.format.separator", default: ".")
      )
    end
  end
end
