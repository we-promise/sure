class Provider::DirectaAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("DirectaAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_item_class
    DirectaItem
  end

  def self.connection_configs(family:)
    user = Current.user
    return [] unless family.can_connect_directa? && user&.family_id == family.id && user.admin? && user.preview_features_enabled?

    [ {
      key: "directa",
      name: I18n.t("providers.directa.name", default: "Directa"),
      description: I18n.t("providers.directa.connection_description", default: "Connect your Directa brokerage account."),
      can_connect: true,
      frame: :_top,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.directa_login_path
      }
    } ]
  end

  def provider_name
    "directa"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_directa_item_path(item)
  end

  def item
    provider_account.directa_item
  end

  def institution_name
    I18n.t("providers.directa.institution_name", default: "Directa")
  end
end
