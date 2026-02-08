class Provider::CoinbaseAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("CoinbaseAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Crypto]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_coinbase?

    [ {
      key: "coinbase",
      name: "Coinbase",
      description: "Link to a Coinbase wallet",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_coinbase_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_coinbase_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "coinbase"
  end

  # Build a Coinbase provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Coinbase, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    coinbase_item = family.coinbase_items.where.not(api_key: nil).first
    return nil unless coinbase_item&.credentials_configured?

    Provider::Coinbase.new(
      api_key: coinbase_item.api_key,
      api_secret: coinbase_item.api_secret
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_coinbase_item_path(item)
  end

  def item
    provider_account.coinbase_item
  end

  def can_delete_holdings?
    false
  end

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
        Rails.logger.warn("Invalid institution URL for Coinbase account #{provider_account.id}: #{url}")
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
