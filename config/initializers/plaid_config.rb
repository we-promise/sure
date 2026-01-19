# Plaid configuration attributes
# These are initialized to nil and loaded lazily on first access by Provider::Registry
# Configuration is loaded from database settings or ENV variables via the adapter's reload_configuration method
Rails.application.configure do
  config.plaid = nil
  config.plaid_eu = nil

  # Plaid pending transaction settings (mirrors SimpleFIN config pattern)
  falsy = %w[0 false no off]
  config.x.plaid ||= ActiveSupport::OrderedOptions.new
  # Default to true - fetch pending transactions for display with "Pending" badge
  # and reconciliation when posted versions arrive (Plaid provides pending_transaction_id for reliable linking)
  # Set PLAID_INCLUDE_PENDING=0 to disable if user prefers not to see pending transactions
  pending_env = ENV["PLAID_INCLUDE_PENDING"].to_s.strip.downcase
  config.x.plaid.include_pending = pending_env.blank? ? true : !falsy.include?(pending_env)
end
