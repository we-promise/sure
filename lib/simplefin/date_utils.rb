# frozen_string_literal: true

module Simplefin
  module DateUtils
    module_function

    # Parses provider-supplied dates that may be String (ISO), Numeric (epoch seconds),
    # Time/DateTime, or Date. Returns a Date or nil when unparseable.
    def parse_provider_date(val)
      return nil if val.nil?

      case val
      when Date
        val
      when Time, DateTime
        val.to_date
      when Integer, Float
        return nil if val.to_i == 0
        Time.at(val).utc.to_date
      when String
        Date.parse(val)
      else
        nil
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
