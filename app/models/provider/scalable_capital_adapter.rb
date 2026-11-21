class Provider::ScalableCapitalAdapter < Provider::Base
  include Provider::Syncable

  Provider::Factory.register("ScalableCapitalAccount", self)

  def provider_name
    "scalable_capital"
  end

  def item
    provider_account.scalable_capital_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_scalable_capital_item_path(item)
  end
end
