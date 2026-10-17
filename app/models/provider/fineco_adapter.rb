class Provider::FinecoAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("FinecoAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    user = Current.user
    return [] unless family.can_connect_fineco? && user&.family_id == family.id && user.admin? && user.preview_features_enabled?

    [ {
      key: "fineco",
      name: I18n.t("providers.fineco.name", default: "Fineco"),
      description: I18n.t("providers.fineco.connection_description", default: "Import Fineco investment positions."),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.fineco_login_path
      }
    } ]
  end

  def provider_name
    "fineco"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_fineco_item_path(item)
  end

  def item
    provider_account.fineco_item
  end

  def can_delete_holdings?
    true
  end

  def institution_domain
    "finecobank.com"
  end

  def institution_name
    "FinecoBank"
  end

  def institution_url
    "https://finecobank.com"
  end
end
