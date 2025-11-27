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

  # Define which account types this provider supports (US region)
  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  # Returns connection configurations for this provider
  # Plaid can return multiple configs (US and EU) depending on family setup
  def self.connection_configs(family:)
    configs = []

    # US configuration
    if family.can_connect_plaid_us?
      configs << {
        key: "plaid_us",
        name: "Plaid",
        description: "Connect to your US bank via Plaid",
        can_connect: true,
        new_account_path: ->(accountable_type, return_to) {
          Rails.application.routes.url_helpers.new_plaid_item_path(
            region: "us",
            accountable_type: accountable_type
          )
        },
        existing_account_path: ->(account_id) {
          Rails.application.routes.url_helpers.select_existing_account_plaid_items_path(
            account_id: account_id,
            region: "us"
          )
        }
      }
    end

    # EU configuration
    if family.can_connect_plaid_eu?
      configs << {
        key: "plaid_eu",
        name: "Plaid (EU)",
        description: "Connect to your EU bank via Plaid",
        can_connect: true,
        new_account_path: ->(accountable_type, return_to) {
          Rails.application.routes.url_helpers.new_plaid_item_path(
            region: "eu",
            accountable_type: accountable_type
          )
        },
        existing_account_path: ->(account_id) {
          Rails.application.routes.url_helpers.select_existing_account_plaid_items_path(
            account_id: account_id,
            region: "eu"
          )
        }
      }
    end

    configs
  end

  # Mutex for thread-safe configuration loading
  # Initialized at class load time to avoid race conditions on mutex creation
  @config_mutex = Mutex.new

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

    # Plaid requires both client_id and secret to be configured
    configured_check { get_value(:client_id).present? && get_value(:secret).present? }
  end

  def provider_name
    "plaid"
  end

  # Thread-safe lazy loading of Plaid US configuration
  # Ensures configuration is loaded exactly once even under concurrent access
  def self.ensure_configuration_loaded
    # Fast path: return immediately if already loaded (no lock needed)
    return if Rails.application.config.plaid.present?

    # Slow path: acquire lock and reload if still needed
    @config_mutex.synchronize do
      # Double-check after acquiring lock (another thread may have loaded it)
      return if Rails.application.config.plaid.present?

      reload_configuration
    end
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
