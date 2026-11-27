class Provider::SharesightAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("SharesightAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_sharesight?

    [ {
      key: "sharesight",
      name: I18n.t("providers.sharesight.name"),
      description: I18n.t("providers.sharesight.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_sharesight_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_sharesight_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "sharesight"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_sharesight_item_path(item)
  end

  def item
    provider_account.sharesight_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "sharesight.com"
  end

  def institution_name
    I18n.t("providers.sharesight.institution_name")
  end

  def institution_url
    "https://www.sharesight.com"
  end

  def institution_color
    "#0d9488"
  end
end
