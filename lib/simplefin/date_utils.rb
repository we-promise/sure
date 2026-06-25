# frozen_string_literal: true

module Simplefin
  module DateUtils
    module_function

    # Parses provider-supplied timestamps that may be String (ISO or epoch string),
    # Numeric (epoch seconds), Time/DateTime, or Date. Returns a Time or nil when
    # unparseable.
    def parse_provider_time(val)
      return nil if val.nil?

      case val
      when Time
        val
      when DateTime
        val.to_time
      when Date
        val.to_time
      when Integer, Float
        return nil if val.to_i == 0
        Time.at(val).utc
      when String
        stripped = val.strip
        return nil if stripped.empty? || stripped == "0"

        if stripped.match?(/\A\d+(?:\.\d+)?\z/)
          Time.at(stripped.to_f).utc
        else
          Time.parse(stripped)
        end
      else
        nil
      end
    rescue ArgumentError, TypeError
      nil
    end

    # Parses provider-supplied dates that may be String (ISO), Numeric (epoch seconds),
    # Time/DateTime, or Date. Returns a Date or nil when unparseable.
    def parse_provider_date(val)
      parse_provider_time(val)&.to_date
    end
  end
end
