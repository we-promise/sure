# frozen_string_literal: true

class Provider::WiseAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("WiseAccount", self)

  def self.supported_account_types
    %w[Depository]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_wise?

    wise_items = family.wise_items.active.ordered

    return [ connection_config_for(nil) ] if wise_items.empty?

    wise_items.map { |item| connection_config_for(item) }
  end

  def provider_name
    "wise"
  end

  def self.build_provider(family: nil, wise_item_id: nil)
    return nil unless family.present?

    item = resolve_wise_item(family, wise_item_id)
    return nil unless item&.credentials_configured?

    Provider::Wise.new(item.token.to_s.strip, base_url: Rails.configuration.x.wise.base_url)
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

  def institution_name
    "Wise"
  end

  def institution_domain
    "wise.com"
  end

  def institution_url
    "https://wise.com"
  end

  def institution_color
    "#9FE870"
  end

  def self.connection_config_for(wise_item)
    path_params = ->(extra = {}) do
      wise_item.present? ? extra.merge(wise_item_id: wise_item.id) : extra
    end

    {
      key: wise_item.present? ? "wise_#{wise_item.id}" : "wise",
      name: wise_item.present? ? I18n.t("wise_items.provider_connection.name", name: wise_item.name) : I18n.t("wise_items.provider_connection.default_name"),
      description: wise_item.present? ? I18n.t("wise_items.provider_connection.description", name: wise_item.name) : I18n.t("wise_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_wise_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_wise_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def self.resolve_wise_item(family, wise_item_id)
    if wise_item_id.present?
      return family.wise_items.active.find_by(id: wise_item_id)
    end

    family.wise_items.active.ordered.first
  end
  private_class_method :resolve_wise_item
end
