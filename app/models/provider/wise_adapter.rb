class Provider::WiseAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("WiseAccount", self)

  def self.supported_account_types
    %w[Depository]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_wise?

    [ {
      key: "wise",
      name: "Wise",
      description: "Connect to your Wise multi-currency account",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_wise_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_wise_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "wise"
  end

  def self.build_provider(family: nil)
    return nil unless family.present?

    wise_item = family.wise_items.where.not(api_token: nil).first
    return nil unless wise_item&.credentials_configured?

    wise_item.wise_provider
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_wise_item_path(item)
  end

  def item
    provider_account.wise_item
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

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end
end
