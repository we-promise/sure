# Up Bank integration runtime configuration
Rails.application.configure do
  # Debug logging for raw Up API responses.
  # When enabled, logs the full raw payload returned by the Up API.
  # Default: false (only log summary info)
  config.x.up.debug_raw = ENV["UP_DEBUG_RAW"].to_s.strip.downcase.in?(%w[1 true yes])
end
