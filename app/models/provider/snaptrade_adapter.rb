class Provider::SnaptradeAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("SnaptradeAccount", self)

  # Define which account types this provider supports
  # SnapTrade specializes in investment/brokerage accounts
  def self.supported_account_types
    %w[Investment Crypto]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_snaptrade?

    [ {
      key: "snaptrade",
      name: I18n.t("providers.snaptrade.name"),
      description: I18n.t("providers.snaptrade.connection_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_snaptrade_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_snaptrade_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "snaptrade"
  end

  # Build a SnapTrade client for a family's connected item, under whichever
  # auth model that item uses.
  # @param family [Family] The family to get a connected item for (required)
  # @return [Provider::Snaptrade, Provider::SnaptradeOauth, nil] nil if the family has no usable connection
  def self.build_provider(family: nil)
    return nil unless family.present?

    family.snaptrade_items.syncable.ordered.filter_map(&:snaptrade_provider).first
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_snaptrade_item_path(item)
  end

  def item
    provider_account.snaptrade_item
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
        Rails.logger.warn("Invalid institution URL for Snaptrade account #{provider_account.id}: #{url}")
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
