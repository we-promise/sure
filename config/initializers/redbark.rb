# Redbark integration runtime configuration
Rails.application.configure do
  # Controls whether pending transactions are included in Redbark syncs
  # When true, adds includePending=true to transaction fetch requests
  # Default: false (only posted transactions)
  config.x.redbark.include_pending = ENV["REDBARK_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes])
end
