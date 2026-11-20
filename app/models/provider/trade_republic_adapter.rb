class Provider::TradeRepublicAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("TradeRepublicAccount", self)

  def self.supported_account_types
    %w[Depository Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_trade_republic?

    [ {
      key: "trade_republic",
      name: I18n.t("providers.trade_republic.name"),
      description: I18n.t("providers.trade_republic.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_trade_republic_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_trade_republic_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "trade_republic"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_trade_republic_item_path(item)
  end

  def item
    provider_account.trade_republic_item
  end

  def can_delete_holdings?
    true
  end

  def institution_domain
    "traderepublic.com"
  end

  def institution_name
    I18n.t("providers.trade_republic.institution_name")
  end

  def institution_url
    "https://www.traderepublic.com"
  end

  def institution_color
    "#1C1C1C"
  end
end
