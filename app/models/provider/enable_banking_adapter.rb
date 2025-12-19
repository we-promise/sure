class Provider::EnableBankingAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("EnableBankingAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_enable_banking?

    [ {
      key: "enable_banking",
      name: "Enable Banking",
      description: "Connect to your bank via Enable Banking",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_enable_banking_item_path(
          accountable_type: accountable_type
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_enable_banking_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "enable_banking"
  end

  # Build an EnableBanking provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::EnableBanking, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    enable_banking_item = family.enable_banking_items.where.not(client_certificate: nil).first
    return nil unless enable_banking_item&.credentials_configured?

    Provider::EnableBanking.new(
      application_id: enable_banking_item.application_id,
      client_certificate: enable_banking_item.client_certificate
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_enable_banking_item_path(item)
  end

  def item
    provider_account.enable_banking_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["domain"]
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || metadata["aspsp_name"] || item&.aspsp_name
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
