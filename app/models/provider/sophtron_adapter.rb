class Provider::SophtronAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("SophtronAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_sophtron?

    [ {
      key: "sophtron",
      name: "Sophtron",
      description: "Connect to your bank via Sophtron's secure API aggregation service.",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_sophtron_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_sophtron_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "sophtron"
  end

  # Build a Sophtron provider instance with family-specific credentials
  # Sophtron is now fully per-family - no global credentials supported
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Sophtron, nil] Returns nil if User ID and Access key is not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    sophtron_item = family.sophtron_items.where.not(user_id: nil, access_key: nil).first
    return nil unless sophtron_item&.credentials_configured?

    Provider::Sophtron.new(
      sophtron_item.user_id,
      sophtron_item.access_key,
      base_url: sophtron_item.effective_base_url
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_sophtron_item_path(item)
  end

  def item
    provider_account.sophtron_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    # Sophtron may provide institution metadata in account data
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Sophtron account #{provider_account.id}: #{url}")
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
