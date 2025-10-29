# PlaidAdapter serves dual purposes:
#
# 1. Configuration Manager (class-level):
#    - Manages Rails.application.config.plaid (US region)
#    - Exposes 3 configurable fields in "Plaid" section of settings UI
#    - PlaidEuAdapter separately manages EU region in "Plaid Eu" section
#
# 2. Instance Adapter (instance-level):
#    - Wraps ALL PlaidAccount instances regardless of region (US or EU)
#    - The PlaidAccount's plaid_item.plaid_region determines which config to use
#    - Delegates to Provider::Registry.plaid_provider_for_region(region)
class Provider::PlaidAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  # Register this adapter with the factory for ALL PlaidAccount instances
  Provider::Factory.register("PlaidAccount", self)

  # Configuration for Plaid US
  configure do
    description <<~DESC
      Setup instructions:
      1. Visit the [Plaid Dashboard](https://dashboard.plaid.com/team/keys) to get your API credentials
      2. Your Client ID and Secret Key are required to enable Plaid bank sync for US/CA banks
      3. For production use, set environment to 'production', for testing use 'sandbox'
    DESC

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
  end

  def provider_name
    "plaid"
  end

  # Reload Plaid US configuration when settings are updated
  def self.reload_configuration
    client_id = config_value(:client_id).presence || ENV["PLAID_CLIENT_ID"]
    secret = config_value(:secret).presence || ENV["PLAID_SECRET"]
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

  def sync_path
    Rails.application.routes.url_helpers.sync_plaid_item_path(item)
  end

  def item
    provider_account.plaid_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    url_string = item&.institution_url
    return nil unless url_string.present?

    begin
      uri = URI.parse(url_string)
      uri.host&.gsub(/^www\./, "")
    rescue URI::InvalidURIError
      Rails.logger.warn("Invalid institution URL for Plaid account #{provider_account.id}: #{url_string}")
      nil
    end
  end

  def institution_name
    item&.name
  end

  def institution_url
    item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
