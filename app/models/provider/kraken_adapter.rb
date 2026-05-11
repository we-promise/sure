# frozen_string_literal: true

class Provider::KrakenAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("KrakenAccount", self)

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_kraken?

    kraken_items = family.kraken_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return [ connection_config_for(nil) ] if kraken_items.empty?

    kraken_items.map { |kraken_item| connection_config_for(kraken_item) }
  end

  def self.build_provider(family: nil, kraken_item_id: nil)
    return nil unless family.present?

    kraken_item = resolve_kraken_item(family, kraken_item_id)
    return nil unless kraken_item&.credentials_configured?

    kraken_item.kraken_provider
  end

  def provider_name
    "kraken"
  end

  def sync_path
    return unless item

    Rails.application.routes.url_helpers.sync_kraken_item_path(item)
  end

  def item
    provider_account.kraken_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    institution_metadata_value("domain")
  end

  def institution_name
    institution_metadata_value("name")
  end

  def institution_url
    institution_metadata_value("url")
  end

  def institution_color
    institution_metadata_value("color")
  end

  def self.connection_config_for(kraken_item)
    path_params = ->(extra = {}) do
      kraken_item.present? ? extra.merge(kraken_item_id: kraken_item.id) : extra
    end

    {
      key: kraken_item.present? ? "kraken_#{kraken_item.id}" : "kraken",
      name: kraken_item.present? ? I18n.t("kraken_items.provider_connection.name", name: kraken_item.name) : I18n.t("kraken_items.provider_connection.default_name"),
      description: kraken_item.present? ? I18n.t("kraken_items.provider_connection.description", name: kraken_item.name) : I18n.t("kraken_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_kraken_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_kraken_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def self.resolve_kraken_item(family, kraken_item_id)
    if kraken_item_id.present?
      item = family.kraken_items.active.credentials_configured.find_by(id: kraken_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    credentialed_items = family.kraken_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return credentialed_items.first if credentialed_items.one?

    nil
  end
  private_class_method :resolve_kraken_item

  private

    def institution_metadata_value(key)
      metadata = provider_account.institution_metadata || {}
      metadata[key] || item&.public_send("institution_#{key}")
    end
end
