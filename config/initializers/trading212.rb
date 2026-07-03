Rails.application.configure do
  truthy = %w[1 true yes on]

  config.x.trading212 ||= ActiveSupport::OrderedOptions.new
  # Enable raw payload debug logging for Trading 212 API responses.
  # DEV-ONLY: the dump may contain PII and is gated to local environments,
  # so it never logs in managed/production.
  config.x.trading212.debug_raw = Rails.env.local? && truthy.include?(ENV["TRADING212_DEBUG_RAW"].to_s.strip.downcase)
end
