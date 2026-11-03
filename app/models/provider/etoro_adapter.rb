class Provider::EtoroAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("EtoroAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_etoro?

    [ {
      key: "etoro",
      name: I18n.t("providers.etoro.name"),
      description: I18n.t("providers.etoro.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_etoro_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_etoro_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "etoro"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_etoro_item_path(item)
  end

  def item
    provider_account.etoro_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "etoro.com"
  end

  def institution_name
    I18n.t("providers.etoro.institution_name")
  end

  def institution_url
    "https://www.etoro.com"
  end

  def institution_color
    "#13C636"
  end
end
