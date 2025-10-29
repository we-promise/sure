# PlaidEuAdapter is a configuration-only manager for Plaid EU credentials.
#
# It does NOT register as a provider type because:
# - There's no separate "PlaidEuAccount" model
# - All PlaidAccounts (regardless of region) use PlaidAdapter as their instance adapter
#
# This class only manages Rails.application.config.plaid_eu, which
# Provider::Registry.plaid_provider_for_region(:eu) uses to create Provider::Plaid instances.
#
# This separation into a distinct adapter class provides:
# - Clear UI separation: "Plaid" vs "Plaid Eu" sections in settings
# - Better UX: Users only configure the region they need
class Provider::PlaidEuAdapter
  include Provider::Configurable

  # Configuration for Plaid EU
  configure do
    description <<~DESC
      Setup instructions:
      1. Visit the [Plaid Dashboard](https://dashboard.plaid.com/team/keys) to get your API credentials
      2. Your Client ID and Secret Key are required to enable Plaid bank sync for European banks
      3. For production use, set environment to 'production', for testing use 'sandbox'
    DESC

    field :client_id,
          label: "Client ID",
          required: false,
          env_key: "PLAID_EU_CLIENT_ID",
          description: "Your Plaid Client ID from the Plaid Dashboard for EU region"

    field :secret,
          label: "Secret Key",
          required: false,
          secret: true,
          env_key: "PLAID_EU_SECRET",
          description: "Your Plaid Secret from the Plaid Dashboard for EU region"

    field :environment,
          label: "Environment",
          required: false,
          env_key: "PLAID_EU_ENV",
          default: "sandbox",
          description: "Plaid environment: sandbox, development, or production"
  end

  # Reload Plaid EU configuration when settings are updated
  def self.reload_configuration
    client_id = config_value(:client_id).presence || ENV["PLAID_EU_CLIENT_ID"]
    secret = config_value(:secret).presence || ENV["PLAID_EU_SECRET"]
    environment = config_value(:environment).presence || ENV["PLAID_EU_ENV"] || "sandbox"

    if client_id.present? && secret.present?
      Rails.application.config.plaid_eu = Plaid::Configuration.new
      Rails.application.config.plaid_eu.server_index = Plaid::Configuration::Environment[environment]
      Rails.application.config.plaid_eu.api_key["PLAID-CLIENT-ID"] = client_id
      Rails.application.config.plaid_eu.api_key["PLAID-SECRET"] = secret
    else
      Rails.application.config.plaid_eu = nil
    end
  end
end
