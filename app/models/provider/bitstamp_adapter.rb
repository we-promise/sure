# frozen_string_literal: true

class Provider::BitstampAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("BitstampAccount", self)

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_bitstamp?

    bitstamp_items = family.bitstamp_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return [ connection_config_for(nil) ] if bitstamp_items.empty?

    bitstamp_items.map { |bitstamp_item| connection_config_for(bitstamp_item) }
  end

  def self.build_provider(family: nil, bitstamp_item_id: nil)
    return nil unless family.present?

    bitstamp_item = resolve_bitstamp_item(family, bitstamp_item_id)
    return nil unless bitstamp_item&.credentials_configured?

    bitstamp_item.bitstamp_provider
  end

  def provider_name
    "bitstamp"
  end

  def sync_path
    return unless item

    Rails.application.routes.url_helpers.sync_bitstamp_item_path(item)
  end

  def item
    provider_account.bitstamp_item
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

  def self.connection_config_for(bitstamp_item)
    path_params = ->(extra = {}) do
      bitstamp_item.present? ? extra.merge(bitstamp_item_id: bitstamp_item.id) : extra
    end

    {
      key: bitstamp_item.present? ? "bitstamp_#{bitstamp_item.id}" : "bitstamp",
      name: bitstamp_item.present? ? I18n.t("bitstamp_items.provider_connection.name", name: bitstamp_item.name) : I18n.t("bitstamp_items.provider_connection.default_name"),
      description: bitstamp_item.present? ? I18n.t("bitstamp_items.provider_connection.description", name: bitstamp_item.name) : I18n.t("bitstamp_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_bitstamp_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_bitstamp_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def self.resolve_bitstamp_item(family, bitstamp_item_id)
    if bitstamp_item_id.present?
      item = family.bitstamp_items.active.credentials_configured.find_by(id: bitstamp_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    credentialed_items = family.bitstamp_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return credentialed_items.first if credentialed_items.one?

    nil
  end
  private_class_method :resolve_bitstamp_item

  private

    def institution_metadata_value(key)
      metadata = provider_account.institution_metadata || {}
      metadata[key] || item&.public_send("institution_#{key}")
    end
end
