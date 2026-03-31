class Provider::BinanceAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("BinanceAccount", self)

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_binance?

    [ {
      key: "binance",
      name: "Binance",
      description: "Link to a Binance spot account",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_binance_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_binance_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def self.build_provider(family: nil)
    return nil unless family.present?

    item = family.binance_items.where.not(api_key: nil).first
    return nil unless item&.credentials_configured?

    Provider::Binance.new(api_key: item.api_key, api_secret: item.api_secret)
  end

  def provider_name
    "binance"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_binance_item_path(item)
  end

  def item
    provider_account.binance_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    provider_account.institution_metadata&.dig("domain") || item&.institution_domain || "binance.com"
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") || item&.institution_name || "Binance"
  end

  def institution_url
    provider_account.institution_metadata&.dig("url") || item&.institution_url || "https://www.binance.com"
  end

  def institution_color
    item&.institution_color || "#F0B90B"
  end
end
