# Plaid configuration attributes
# These are initialized to nil and loaded lazily on first access by Provider::Registry
# Configuration is loaded from database settings or ENV variables via the adapter's reload_configuration method
Rails.application.configure do
  config.plaid = nil
  config.plaid_eu = nil
end
