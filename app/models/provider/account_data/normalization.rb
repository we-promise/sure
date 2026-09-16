require "bigdecimal"
require "date"
require "time"

# Shared value parsing; provider adapters still choose signs, identity and dates.
module Provider::AccountData::Normalization
  private
    def normalized_decimal(value)
      unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(BigDecimal)
        raise ArgumentError, "Expected an exact monetary value"
      end
      number = BigDecimal(value.to_s)
      raise ArgumentError, "Expected a finite monetary value" unless number.finite?
      number
    end

    def normalized_currency(value, fallback: nil)
      [ value, fallback ].each do |candidate|
        next unless candidate.is_a?(String)
        code = candidate.strip.upcase
        next unless code.match?(/\A[A-Z]{3}\z/)
        begin
          Money::Currency.new(code)
          return code
        rescue Money::Currency::UnknownCurrencyError
          next
        end
      end
      raise ArgumentError, "Expected a recognized currency"
    end

    def normalized_date(value, timezone:)
      return value if value.instance_of?(Date)
      return value.in_time_zone(timezone).to_date if value.is_a?(Time) || value.is_a?(DateTime)
      if value.is_a?(Integer) || value.is_a?(Float)
        raise ArgumentError unless value.finite?
        return Time.at(value).in_time_zone(timezone).to_date
      end
      raise ArgumentError unless value.is_a?(String) && value.present?
      return Date.iso8601(value) unless value.match?(/[T:]/)
      raise ArgumentError unless value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Date.iso8601(value.split("T", 2).first)
      Time.iso8601(value).in_time_zone(timezone).to_date
    end

    def normalized_object(value)
      raise ArgumentError, "Expected an object" unless value.is_a?(Hash)
      value.with_indifferent_access
    end

    def normalized_id(value)
      unless (value.is_a?(String) || value.is_a?(Integer)) && value.to_s.present?
        raise ArgumentError, "Expected an identifier"
      end
      value.to_s
    end

    alias_method :decimal, :normalized_decimal

    def known_currency(value)
      normalized_currency(value)
    rescue ArgumentError
      nil
    end

    def date_in_zone(value)
      normalized_date(value, timezone: @timezone)
    end

    def checked_page(result)
      unless result.is_a?(Hash) && result[:items].is_a?(Array) && result.key?(:next_cursor) &&
          (result[:next_cursor].nil? || (result[:next_cursor].is_a?(String) && result[:next_cursor].present?))
        raise ArgumentError, "Invalid provider page"
      end
      result
    end
end
