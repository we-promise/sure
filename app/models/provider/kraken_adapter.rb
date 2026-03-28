class Provider::KrakenAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("KrakenAccount", self)

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_kraken?

    [ {
      key: "kraken",
      name: "Kraken",
      description: "Link to a Kraken spot account",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_kraken_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_kraken_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def self.build_provider(family: nil)
    return nil unless family.present?

    kraken_item = family.kraken_items.where.not(api_key: nil).first
    return nil unless kraken_item&.credentials_configured?

    Provider::Kraken.new(
      api_key: kraken_item.api_key,
      api_secret: kraken_item.api_secret
    )
  end

  def provider_name
    "kraken"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_kraken_item_path(item)
  end

  def item
    provider_account.kraken_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "kraken.com"
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") || item&.institution_name || "Kraken"
  end

  def institution_url
    item&.institution_url || "https://www.kraken.com"
  end

  def institution_color
    item&.institution_color || "#1A1A1A"
  end
end
