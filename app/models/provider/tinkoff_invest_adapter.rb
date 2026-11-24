class Provider::TinkoffInvestAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("TinkoffInvestAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_tinkoff_invest?

    [ {
      key: "tinkoff_invest",
      name: I18n.t("providers.tinkoff_invest.name"),
      description: I18n.t("providers.tinkoff_invest.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_tinkoff_invest_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_tinkoff_invest_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "tinkoff_invest"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_tinkoff_invest_item_path(item)
  end

  def item
    provider_account.tinkoff_invest_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "tbank.ru"
  end

  def institution_name
    I18n.t("providers.tinkoff_invest.institution_name")
  end

  def institution_url
    "https://www.tbank.ru/invest/"
  end

  def institution_color
    "#FFDD2D"
  end
end
