class Provider::CaAutoBankAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("CaAutoBankAccount", self)

  def self.supported_account_types
    %w[Depository]
  end

  def self.connection_item_class
    CaAutoBankItem
  end

  def self.connection_configs(family:)
    user = Current.user
    return [] unless family.can_connect_ca_auto_bank? && user&.family_id == family.id && user.admin? && user.preview_features_enabled?

    [ { key: "ca_auto_bank", name: I18n.t("ca_auto_bank.name"), description: I18n.t("ca_auto_bank.connection_description"),
      can_connect: true, frame: :_top, new_account_path: ->(_type, _return_to) { Rails.application.routes.url_helpers.ca_auto_bank_login_path } } ]
  end

  def provider_name
    "ca_auto_bank"
  end

  def item
    provider_account.ca_auto_bank_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_ca_auto_bank_item_path(item)
  end

  def institution_name
    "CA Auto Bank"
  end

  def requires_update?
    item.reconnect_required?
  end
end
