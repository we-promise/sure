class Provider::StashawayAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("StashawayAccount", self)

  def self.supported_account_types
    %w[Investment Depository]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_stashaway?

    [ {
      key: "stashaway",
      name: I18n.t("providers.stashaway.name"),
      description: I18n.t("providers.stashaway.connection_description"),
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_accounts_stashaway_items_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_stashaway_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "stashaway"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_stashaway_item_path(item)
  end

  def item
    provider_account.stashaway_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "stashaway.sg"
  end

  def institution_name
    I18n.t("providers.stashaway.institution_name")
  end

  def institution_url
    "https://www.stashaway.sg"
  end

  def institution_color
    "#2563eb"
  end
end
