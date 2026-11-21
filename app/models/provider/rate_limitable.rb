# Shared concern for providers that need interval-based request throttling
# and a standard error transformation pattern.
#
# Providers that include this concern get:
# - `throttle_request`: sleeps to enforce MIN_REQUEST_INTERVAL between calls
# - `min_request_interval`: reads from ENV with fallback to the class constant
# - `default_error_transformer`: maps Faraday/rate-limit errors to provider-scoped types
# - `env_positive_integer` / `env_interval` from Provider::EnvTuning, for other overrides
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
  include Provider::EnvTuning

  # Runs a hook immediately before every HTTP attempt, including retries, so
  # each one can be throttled and counted against a request budget. Register it
  # after the :retry middleware: the retry middleware re-invokes the downstream
  # stack on each attempt, so a hook downstream of it sees every attempt, while
  # a call made once before client.get only sees the initial request.
  class BeforeEachAttempt < Faraday::Middleware
    def initialize(app, hook)
      super(app)
      @hook = hook
    end

    def on_request(env)
      @hook.call(env)
    end
  end

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
      key = "#{provider_env_prefix}_MIN_REQUEST_INTERVAL"
      positive_interval(ENV.fetch(key, self.class::MIN_REQUEST_INTERVAL), key)
    end

    # <PREFIX>_MIN_REQUEST_INTERVAL is strict for these providers: a value that does not
    # parse, or is not positive, raises rather than turning pacing off (`"invalid".to_f` is
    # 0). Caps and Twelve Data's interval go through Provider::EnvTuning instead, which falls
    # back to the default with a warning.
    def positive_interval(value, key)
      interval = Float(value, exception: false)
      raise ArgumentError, "#{key} must be a positive number of seconds, got #{value.inspect}" if interval.nil? || !interval.finite? || interval <= 0

      interval
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
