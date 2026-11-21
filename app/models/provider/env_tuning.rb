# Reads a provider's tuning overrides (request caps, pacing intervals) from ENV. A blank
# value is unset. A value that does not parse, or is out of range, is ignored: the default
# applies, so a typo cannot refuse, stall or unpace every request, and a warning names the
# variable once per process for each bad value, not on every request. ENV is read on every
# call, so a corrected value takes effect without a restart.
module Provider::EnvTuning
  WARNED = Concurrent::Set.new

  private
    # A positive whole number in base 10: "010" is 10; "0x10", "1e3" and "0" are rejected.
    def env_positive_integer(key, default)
      env_tuning(key, default, "a positive whole number") do |raw|
        value = Integer(raw, 10, exception: false)
        value if value&.positive?
      end
    end

    # Seconds between requests: a finite number, zero (no pause) included.
    def env_interval(key, default)
      env_tuning(key, default, "a number of seconds, 0 or more") do |raw|
        value = Float(raw, exception: false)
        value if value&.finite? && value >= 0
      end
    end

    def env_tuning(key, default, expected)
      raw = ENV[key]
      return default if raw.blank?

      value = yield(raw.strip)
      return value unless value.nil?

      if WARNED.add?([ key, raw ])
        Rails.logger.warn("#{key} must be #{expected}, got #{raw.inspect}; using #{default}")
      end
      default
    end
end
