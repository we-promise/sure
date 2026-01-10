# Provider adapter for CoinStats cryptocurrency wallet integration.
# Handles sync operations and institution metadata for crypto accounts.
class Provider::CoinstatsAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("CoinstatsAccount", self)

  # @return [Array<String>] Account types supported by this provider
  def self.supported_account_types
    %w[Crypto]
  end

  # Returns connection configurations for this provider
  # @param family [Family] The family to check connection eligibility
  # @return [Array<Hash>] Connection config with name, description, and paths
  def self.connection_configs(family:)
    return [] unless family.can_connect_coinstats?

    [ {
      key: "coinstats",
      name: "CoinStats",
      description: "Connect to your crypto wallet via CoinStats",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_coinstats_item_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      # CoinStats wallets are linked via the link_wallet action, not via existing account selection
      existing_account_path: nil
    } ]
  end

  # @return [String] Unique identifier for this provider
  def provider_name
    "coinstats"
  end

  # Build a Coinstats provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Coinstats, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    coinstats_item = family.coinstats_items.where.not(api_key: nil).first
    return nil unless coinstats_item&.credentials_configured?

    Provider::Coinstats.new(coinstats_item.api_key)
  end

  # @return [String] URL path for triggering a sync
  def sync_path
    Rails.application.routes.url_helpers.sync_coinstats_item_path(item)
  end

  # @return [CoinstatsItem] The parent item containing API credentials
  def item
    provider_account.coinstats_item
  end

  # @return [Boolean] Whether holdings can be manually deleted
  def can_delete_holdings?
    false
  end

  # Extracts institution domain from metadata, deriving from URL if needed.
  # @return [String, nil] Domain name or nil if unavailable
  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Coinstats account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  # @return [String, nil] Institution display name
  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"]
  end

  # @return [String, nil] Institution website URL
  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"]
  end

  # @return [nil] CoinStats doesn't provide institution colors
  def institution_color
    nil # CoinStats doesn't provide institution colors
  end

  # @return [String, nil] URL for institution/token logo
  def logo_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["logo"]
  end
end
