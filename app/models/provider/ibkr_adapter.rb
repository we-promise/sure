class Provider::IbkrAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("IbkrAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_ibkr?

    ibkr_items = family.ibkr_items.active.ordered.select(&:credentials_configured?)

    # With a single connection (or none yet) keep one generic entry; with
    # several, offer one entry per connection so the user picks which one.
    return [ connection_config_for(nil) ] if ibkr_items.size <= 1

    ibkr_items.map { |ibkr_item| connection_config_for(ibkr_item) }
  end

  def self.connection_config_for(ibkr_item)
    url_helpers = Rails.application.routes.url_helpers

    {
      key: ibkr_item.present? ? "ibkr_#{ibkr_item.id}" : "ibkr",
      name: ibkr_item.present? ? I18n.t("providers.ibkr.named_connection", name: ibkr_item.name) : I18n.t("providers.ibkr.name"),
      description: ibkr_item.present? ? I18n.t("providers.ibkr.named_connection_description", name: ibkr_item.name) : I18n.t("providers.ibkr.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        if ibkr_item.present?
          url_helpers.select_accounts_ibkr_items_path(ibkr_item_id: ibkr_item.id)
        else
          url_helpers.select_accounts_ibkr_items_path
        end
      },
      existing_account_path: ->(account_id) {
        if ibkr_item.present?
          url_helpers.select_existing_account_ibkr_items_path(account_id: account_id, ibkr_item_id: ibkr_item.id)
        else
          url_helpers.select_existing_account_ibkr_items_path(account_id: account_id)
        end
      }
    }
  end
  private_class_method :connection_config_for

  def provider_name
    "ibkr"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_ibkr_item_path(item)
  end

  def item
    provider_account.ibkr_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "interactivebrokers.com"
  end

  def institution_name
    I18n.t("providers.ibkr.institution_name")
  end

  def institution_url
    "https://www.interactivebrokers.com"
  end

  def institution_color
    "#D32F2F"
  end
end
