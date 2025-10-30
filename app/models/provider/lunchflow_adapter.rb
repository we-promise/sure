class Provider::LunchflowAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  # Register this adapter with the factory
  Provider::Factory.register("LunchflowAccount", self)

  # Configuration for Lunchflow
  configure do
    description <<~DESC
      Setup instructions:
      1. Visit [Lunchflow](https://www.lunchflow.app) to get your API key
      2. Enter your API key below to enable Lunchflow bank data sync
      3. Choose the appropriate environment (production or staging)
    DESC

    field :api_key,
          label: "API Key",
          required: true,
          secret: true,
          env_key: "LUNCHFLOW_API_KEY",
          description: "Your Lunchflow API key for authentication"

    field :base_url,
          label: "Base URL",
          required: false,
          env_key: "LUNCHFLOW_BASE_URL",
          default: "https://lunchflow.app/api/v1",
          description: "Base URL for Lunchflow API"
  end

  def provider_name
    "lunchflow"
  end

  # Build a Lunchflow provider instance with configured credentials
  # @return [Provider::Lunchflow, nil] Returns nil if API key is not configured
  def self.build_provider
    api_key = config_value(:api_key)
    return nil unless api_key.present?

    base_url = config_value(:base_url).presence || "https://lunchflow.app/api/v1"
    Provider::Lunchflow.new(api_key, base_url: base_url)
  end

  # Reload Lunchflow configuration when settings are updated
  def self.reload_configuration
    # Lunchflow doesn't need to configure Rails.application.config like Plaid does
    # The configuration is read dynamically via config_value(:api_key) and config_value(:base_url)
    # This method exists to be called by the settings controller after updates
    # No action needed here since values are fetched on-demand
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_lunchflow_item_path(item)
  end

  def item
    provider_account.lunchflow_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    # Lunchflow may provide institution metadata in account data
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Lunchflow account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
