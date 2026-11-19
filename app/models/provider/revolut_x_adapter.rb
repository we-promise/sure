# frozen_string_literal: true

class Provider::RevolutXAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("RevolutXAccount", self)
  declares_connection key: "revolut_x", name: "Revolut X", panel: true,
                      metadata: { region: "Global", kinds: %w[Crypto], maturity: :beta, logo_text: "RX", logo_color: "#111827", domain: "revolut.com" },
                      lists: {
                        settings_page: %i[active ordered],
                        settings_panel: %i[active ordered],
                        accounts_index: ->(items) { items.ordered.includes(:revolut_x_accounts, :accounts) }
                      }

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_revolut_x?

    items = family.revolut_x_items.syncable.ordered.select(&:credentials_configured?)
    return [ connection_config_for(nil) ] if items.empty?

    items.map { |revolut_x_item| connection_config_for(revolut_x_item) }
  end

  def provider_name
    "revolut_x"
  end

  def sync_path
    return unless item

    Rails.application.routes.url_helpers.sync_revolut_x_item_path(item)
  end

  def item
    provider_account.revolut_x_item
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

  def self.connection_config_for(revolut_x_item)
    path_params = ->(extra = {}) do
      revolut_x_item.present? ? extra.merge(revolut_x_item_id: revolut_x_item.id) : extra
    end

    {
      key: revolut_x_item.present? ? "revolut_x_#{revolut_x_item.id}" : "revolut_x",
      name: revolut_x_item.present? ? I18n.t("revolut_x_items.provider_connection.name", name: revolut_x_item.name) : I18n.t("revolut_x_items.provider_connection.default_name"),
      description: revolut_x_item.present? ? I18n.t("revolut_x_items.provider_connection.description", name: revolut_x_item.name) : I18n.t("revolut_x_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_revolut_x_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_revolut_x_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  private

    def institution_metadata_value(key)
      metadata = provider_account.institution_metadata || {}
      metadata[key] || item&.public_send("institution_#{key}")
    end
end
