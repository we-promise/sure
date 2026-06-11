require "bigdecimal"

module TaxWorkbook
  class ValueParser
    TRUE_VALUES = %w[true t yes y 1].freeze
    FALSE_VALUES = %w[false f no n 0].freeze
    GSTIN_PATTERN = /\A\d{2}[A-Z0-9]{13}\z/
    TAN_PATTERN = /\A[A-Z]{4}\d{5}[A-Z]\z/
    PAN_PATTERN = /\A[A-Z]{5}\d{4}[A-Z]\z/

    def decimal(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s.delete(","))
    rescue ArgumentError, TypeError
      raise ArgumentError, "must be a decimal number"
    end

    def boolean(value)
      normalized = value.to_s.strip.downcase
      return true if TRUE_VALUES.include?(normalized)
      return false if FALSE_VALUES.include?(normalized)

      raise ArgumentError, "must be true or false"
    end

    def date(value)
      case value
      when Date
        value
      when Time, DateTime
        value.to_date
      else
        raise ArgumentError if value.blank?

        Date.parse(value.to_s)
      end
    rescue ArgumentError, Date::Error
      raise ArgumentError, "must be a date"
    end

    def month(value)
      return value.to_date.beginning_of_month if value.is_a?(Date) || value.is_a?(Time) || value.is_a?(DateTime)

      normalized = value.to_s.strip
      if normalized.match?(/\A\d{4}-\d{2}\z/)
        Date.strptime("#{normalized}-01", "%Y-%m-%d")
      elsif normalized.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(normalized).beginning_of_month
      else
        raise ArgumentError
      end
    rescue ArgumentError, Date::Error
      raise ArgumentError, "must be a month like YYYY-MM"
    end

    def quarter(value)
      normalized = value.to_s.strip.upcase.delete(" ")
      return normalized if normalized.in?(%w[Q1 Q2 Q3 Q4])

      raise ArgumentError, "must be Q1, Q2, Q3, or Q4"
    end

    def gstin(value)
      normalized = compact_identifier(value)
      raise ArgumentError, "must be a 15-character GSTIN" unless normalized.match?(GSTIN_PATTERN)

      normalized
    end

    def tan(value)
      normalized = compact_identifier(value)
      raise ArgumentError, "must be a 10-character TAN" unless normalized.match?(TAN_PATTERN)

      normalized
    end

    def pan(value)
      normalized = compact_identifier(value)
      raise ArgumentError, "must be a 10-character PAN" unless normalized.match?(PAN_PATTERN)

      normalized
    end

    private
      def compact_identifier(value)
        value.to_s.upcase.gsub(/\s+/, "")
      end
  end
end
