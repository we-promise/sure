class Provider::TruelayerAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("TruelayerAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard Loan]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_truelayer?

    [ {
      key: "truelayer",
      name: "TrueLayer",
      description: I18n.t("providers.truelayer.description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.settings_providers_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_truelayer_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "truelayer"
  end

  def self.build_provider(family: nil)
    return nil unless family.present?

    truelayer_item = family.truelayer_items.where.not(client_id: nil).first
    truelayer_item&.truelayer_provider
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_truelayer_item_path(item)
  end

  def item
    provider_account.truelayer_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    nil
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") || item&.institution_name
  end

  def institution_url
    nil
  end

  def institution_color
    item&.institution_color
  end
end
