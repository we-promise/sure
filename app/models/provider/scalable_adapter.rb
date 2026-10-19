class Provider::ScalableAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("ScalableAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_item_class
    ScalableItem
  end

  def self.connection_configs(family:)
    user = Current.user
    return [] if Current.session&.active_impersonator_session_id.present?
    return [] unless family.can_connect_scalable? && user&.family_id == family.id && user.admin? && user.preview_features_enabled?

    [ {
      key: "scalable",
      name: I18n.t("providers.scalable.name", default: "Scalable Capital"),
      description: I18n.t("providers.scalable.connection_description", default: "Connect your Scalable Capital investment account and view its brokerage cash and holdings."),
      can_connect: true,
      frame: :_top,
      new_account_path: ->(_accountable_type, _return_to) { Rails.application.routes.url_helpers.scalable_login_path }
    } ]
  end

  def provider_name
    "scalable"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_scalable_item_path(item)
  end

  def item
    provider_account.scalable_item
  end

  def institution_name
    "Scalable Capital"
  end

  def institution_domain
    "scalable.capital"
  end

  def requires_update?
    item.requires_update?
  end
end
