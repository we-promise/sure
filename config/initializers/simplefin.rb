Rails.application.configure do
  truthy = %w[1 true yes on]
  falsy = %w[0 false no off]

  config.x.simplefin ||= ActiveSupport::OrderedOptions.new
  # Default to true - always fetch pending transactions so they can be:
  # - Displayed with a "Pending" badge
  # - Excluded from budgets (but included in net worth)
  # - Reconciled when posted versions arrive (avoiding duplicates)
  # - Auto-excluded after 8 days if they remain stale
  # Set SIMPLEFIN_INCLUDE_PENDING=0 to disable if a bank's integration causes issues
  pending_env = ENV["SIMPLEFIN_INCLUDE_PENDING"].to_s.strip.downcase
  config.x.simplefin.include_pending = pending_env.blank? ? true : !falsy.include?(pending_env)
  config.x.simplefin.debug_raw = truthy.include?(ENV["SIMPLEFIN_DEBUG_RAW"].to_s.strip.downcase)
end
