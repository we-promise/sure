class Provider::SaxoAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("SaxoAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless Current.user&.preview_features_enabled?

    [ {
      key: "saxo",
      name: "Saxo Bank",
      description: I18n.t("saxo.description"),
      can_connect: true,
      new_account_path: ->(*) { Rails.application.routes.url_helpers.new_saxo_item_path },
      existing_account_path: ->(*) { Rails.application.routes.url_helpers.settings_providers_path }
    } ]
  end

  def provider_name
    "saxo"
  end

  def item
    provider_account.saxo_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_saxo_item_path(item)
  end

  def institution_domain
    "home.saxo"
  end

  def institution_name
    "Saxo Bank"
  end

  def institution_url
    "https://www.home.saxo"
  end
end
