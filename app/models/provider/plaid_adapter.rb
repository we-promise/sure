# Plaid global configuration (admin-managed Rails.application.config.plaid).
#
# Holds the Provider::Configurable DSL block that registers Plaid in the
# Settings → Providers UI for client_id / secret / environment management.
# This is global config (one set for the app), distinct from per-family BYOK
# credentials managed via Provider::FamilyConfig.
#
# After the Plaid framework cutover, the connection-side adapter logic lives in
# Provider::Plaid::Adapter (registered with Provider::ConnectionRegistry).
# This file is reduced to its remaining role: hosting the configuration DSL
# block that manages Rails.application.config.plaid for the US region.
# Provider::PlaidEuAdapter handles the EU region equivalently.
class Provider::PlaidAdapter
  include Provider::Configurable

  @config_mutex = Mutex.new

  configure do
    # Setup instructions render via SettingsHelper#provider_setup_instructions
    # (driven by I18n at settings.providers.instructions.plaid). The framework
    # panel inserts that block above this form — single source of truth.

    field :client_id,
          label: "Client ID",
          required: false,
          env_key: "PLAID_CLIENT_ID",
          description: "Your Plaid Client ID from the Plaid Dashboard"

    field :secret,
          label: "Secret Key",
          required: false,
          secret: true,
          env_key: "PLAID_SECRET",
          description: "Your Plaid Secret from the Plaid Dashboard"

    field :environment,
          label: "Environment",
          required: false,
          env_key: "PLAID_ENV",
          default: "sandbox",
          description: "Plaid environment: sandbox, development, or production"

    configured_check { get_value(:client_id).present? && get_value(:secret).present? }
  end

  # Thread-safe lazy loading of Plaid US configuration. Ensures configuration is
  # loaded exactly once even under concurrent access.
  def self.ensure_configuration_loaded
    return if Rails.application.config.plaid.present?
    @config_mutex.synchronize do
      return if Rails.application.config.plaid.present?
      reload_configuration
    end
  end

  # Reload Plaid US configuration when settings are updated.
  def self.reload_configuration
    client_id   = config_value(:client_id).presence || ENV["PLAID_CLIENT_ID"]
    secret      = config_value(:secret).presence    || ENV["PLAID_SECRET"]
    environment = config_value(:environment).presence || ENV["PLAID_ENV"] || "sandbox"

    if client_id.present? && secret.present?
      Rails.application.config.plaid = Plaid::Configuration.new
      Rails.application.config.plaid.server_index = Plaid::Configuration::Environment[environment]
      Rails.application.config.plaid.api_key["PLAID-CLIENT-ID"] = client_id
      Rails.application.config.plaid.api_key["PLAID-SECRET"] = secret
    else
      Rails.application.config.plaid = nil
    end
  end
end
