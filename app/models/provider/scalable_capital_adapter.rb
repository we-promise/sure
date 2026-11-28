class Provider::ScalableCapitalAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("ScalableCapitalAccount", self)

  def provider_name
    "scalable_capital"
  end

  def institution_domain
    Provider::Metadata.for(provider_name)[:domain]
  end

  def institution_name
    I18n.t("scalable_capital_items.accounts.title")
  end

  def item
    provider_account.scalable_capital_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_scalable_capital_item_path(item)
  end
end
