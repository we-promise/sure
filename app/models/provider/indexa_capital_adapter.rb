class Provider::IndexaCapitalAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("IndexaCapitalAccount", self)

  # Indexa Capital supports index fund and pension plan investments
  def self.supported_account_types
    %w[Investment]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_indexa_capital?

    [ {
      key: "indexa_capital",
      name: "Indexa Capital",
      description: "Connect to your Indexa Capital account",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_indexa_capital_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_indexa_capital_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "indexa_capital"
  end

  # Build a IndexaCapital provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::IndexaCapital, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    indexa_capital_item = family.indexa_capital_items.order(created_at: :desc).first
    return nil unless indexa_capital_item&.credentials_configured?

    indexa_capital_item.indexa_capital_provider
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_indexa_capital_item_path(item)
  end

  def item
    provider_account.indexa_capital_item
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
        Rails.logger.warn("Invalid institution URL for IndexaCapital account #{provider_account.id}: #{url}")
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
