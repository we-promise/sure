class Provider::QuestradeAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("QuestradeAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    # Questrade is a stock/ETF/options brokerage, so it only links to
    # Investment accounts (not Crypto).
    %w[Investment]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_questrade?

    [ {
      key: "questrade",
      name: "Questrade",
      description: "Connect to your brokerage via Questrade",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_questrade_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_questrade_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "questrade"
  end

  # Build a Questrade provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Questrade, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    questrade_item = family.questrade_items.where.not(refresh_token: nil).first
    return nil unless questrade_item&.credentials_configured?

    questrade_item.questrade_provider
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_questrade_item_path(item)
  end

  def item
    provider_account.questrade_item
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
        Rails.logger.warn("Invalid institution URL for Questrade account #{provider_account.id}: #{url}")
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
