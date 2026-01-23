class Provider::MercuryAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("MercuryAccount", self)

  # Define which account types this provider supports
  # Mercury is primarily a business banking provider with checking/savings accounts
  def self.supported_account_types
    %w[Depository]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_mercury?

    [ {
      key: "mercury",
      name: "Mercury",
      description: "Connect to your bank via Mercury",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_mercury_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_mercury_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "mercury"
  end

  # Build a Mercury provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Mercury, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    mercury_item = family.mercury_items.where.not(token: nil).first
    return nil unless mercury_item&.credentials_configured?

    Provider::Mercury.new(
      mercury_item.token,
      base_url: mercury_item.effective_base_url
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_mercury_item_path(item)
  end

  def item
    provider_account.mercury_item
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
        Rails.logger.warn("Invalid institution URL for Mercury account #{provider_account.id}: #{url}")
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
