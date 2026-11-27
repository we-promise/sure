class Provider::MoomooAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("MoomooAccount", self)

  # Cash accounts of a moomoo account split by currency are Depository
  # accounts (see MoomooAccount#sure_accountable).
  def self.supported_account_types
    %w[Depository Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_moomoo?

    [ {
      key: "moomoo",
      name: I18n.t("providers.moomoo.name"),
      description: I18n.t("providers.moomoo.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_moomoo_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_moomoo_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "moomoo"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_moomoo_item_path(item)
  end

  def item
    provider_account.moomoo_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "moomoo.com"
  end

  def institution_name
    I18n.t("providers.moomoo.institution_name")
  end

  def institution_url
    "https://www.moomoo.com"
  end

  def institution_color
    "#FF6A00"
  end
end
