Rails.application.configure do
  # Initialize Plaid configuration to nil
  config.plaid = nil
  config.plaid_eu = nil
end

# Load Plaid configuration from adapters after initialization
Rails.application.config.after_initialize do
  # Skip if database is not ready (e.g., during db:create)
  next unless ActiveRecord::Base.connection.table_exists?("settings")

  # Ensure provider adapters are loaded
  Provider::Factory.ensure_adapters_loaded

  # Reload configurations from settings/ENV
  Provider::PlaidAdapter.reload_configuration      # US region
  Provider::PlaidEuAdapter.reload_configuration    # EU region
rescue ActiveRecord::NoDatabaseError, PG::ConnectionBad
  # Database doesn't exist yet, skip initialization
  nil
end
