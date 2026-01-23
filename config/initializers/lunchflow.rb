# Lunchflow integration runtime configuration
Rails.application.configure do
  # Controls whether pending transactions are included in Lunchflow syncs
  # When true, adds include_pending=true to transaction fetch requests
  # Default: false (only posted/settled transactions)
  config.x.lunchflow.include_pending = ENV["LUNCHFLOW_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes])

  # Debug logging for raw Lunchflow API responses
  # When enabled, logs the full raw JSON payload from Lunchflow API
  # Default: false (only log summary info)
  config.x.lunchflow.debug_raw = ENV["LUNCHFLOW_DEBUG_RAW"].to_s.strip.downcase.in?(%w[1 true yes])
end
