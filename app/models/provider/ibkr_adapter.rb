class Provider::IbkrAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("IbkrAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_ibkr?

    [ {
      key: "ibkr",
      name: I18n.t("providers.ibkr.name"),
      description: I18n.t("providers.ibkr.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_ibkr_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_ibkr_items_path(account_id: account_id)
      }
    } ]
  end

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
