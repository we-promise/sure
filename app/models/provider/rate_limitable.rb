# Shared concern for providers that need interval-based request throttling
# and a standard error transformation pattern.
#
# Providers that include this concern get:
# - `throttle_request`: sleeps to enforce MIN_REQUEST_INTERVAL between calls
# - `min_request_interval`: reads from ENV with fallback to the class constant
# - `default_error_transformer`: maps Faraday/rate-limit errors to provider-scoped types
#
# The including class MUST define:
# - `MIN_REQUEST_INTERVAL` (Float) — default seconds between requests
# - `Error` (Class)           — provider-scoped error class
# - `RateLimitError` (Class)  — provider-scoped rate-limit error class
#
# And MAY define a `PROVIDER_ENV_PREFIX` constant (e.g. "ALPHA_VANTAGE") used
# to derive the ENV key for the min request interval override.  When omitted
# the prefix is derived from the class name (Provider::AlphaVantage → "ALPHA_VANTAGE").
module Provider::RateLimitable
  extend ActiveSupport::Concern

  private
    # Enforces a minimum interval between consecutive requests on this instance.
    # Subclasses that need additional rate-limit layers (daily counters, hourly
    # counters) should call `super` or invoke this via `throttle_interval` and
    # add their own checks.
    def throttle_request
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0
      @last_request_time = Time.current
    end

    def min_request_interval
      ENV.fetch("#{provider_env_prefix}_MIN_REQUEST_INTERVAL", self.class::MIN_REQUEST_INTERVAL).to_f
    end

    def provider_env_prefix
      self.class.const_defined?(:PROVIDER_ENV_PREFIX) ? self.class::PROVIDER_ENV_PREFIX : self.class.name.demodulize.underscore.upcase
    end

    # Standard error transformation: maps common Faraday errors to provider-scoped
    # error classes.  Providers with extra error types (e.g. AuthenticationError)
    # should override and call `super` for the default cases.
    def default_error_transformer(error)
      case error
      when self.class::RateLimitError
        error
      when Faraday::TooManyRequestsError
        self.class::RateLimitError.new(
          "#{self.class.name.demodulize} rate limit exceeded",
          details: error.response&.dig(:body)
        )
      when Faraday::Error
        self.class::Error.new(error.message, details: error.response&.dig(:body))
      else
        self.class::Error.new(error.message)
      end
    end
end
