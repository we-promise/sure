# frozen_string_literal: true

module WiseAccount::DataHelpers
  extend ActiveSupport::Concern

  private

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal then value
      when String     then BigDecimal(value)
      when Numeric    then BigDecimal(value.to_s)
      else nil
      end
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      return nil if value.nil?

      case value
      when Date   then value
      when String then Time.zone.parse(value)&.to_date
      when Time, DateTime, ActiveSupport::TimeWithZone then value.to_date
      else nil
      end
    rescue ArgumentError, TypeError
      nil
    end
end
