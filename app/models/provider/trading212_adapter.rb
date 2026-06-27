class Provider::Trading212Adapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("Trading212Account", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_trading212?

    [ {
      key: "trading212",
      name: I18n.t("providers.trading212.name"),
      description: I18n.t("providers.trading212.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_trading212_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_trading212_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "trading212"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_trading212_item_path(item)
  end

  def item
    provider_account.trading212_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "trading212.com"
  end

  def institution_name
    I18n.t("providers.trading212.institution_name")
  end

  def institution_url
    "https://www.trading212.com"
  end

  def institution_color
    "#2A9D8F"
  end
end
