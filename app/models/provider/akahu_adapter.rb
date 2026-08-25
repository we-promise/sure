class Provider::AkahuAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("AkahuAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_akahu?

    family.akahu_items.active.ordered.select(&:credentials_configured?).map do |akahu_item|
      connection_config_for(akahu_item)
    end
  end

  def self.build_provider(family: nil, akahu_item_id: nil)
    return nil unless family.present?

    akahu_item = resolve_akahu_item(family, akahu_item_id)
    return nil unless akahu_item&.credentials_configured?

    Provider::Akahu.new(
      app_token: akahu_item.app_token,
      user_token: akahu_item.user_token
    )
  end

  def self.connection_config_for(akahu_item)
    path_params = ->(extra = {}) { extra.merge(akahu_item_id: akahu_item.id) }

    {
      key: "akahu_#{akahu_item.id}",
      name: akahu_item.name.presence || I18n.t("providers.akahu.name"),
      description: I18n.t("providers.akahu.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_akahu_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_akahu_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def provider_name
    "akahu"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_akahu_item_path(item)
  end

  def item
    provider_account.akahu_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["domain"]
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end

  def self.resolve_akahu_item(family, akahu_item_id)
    if akahu_item_id.present?
      item = family.akahu_items.active.find_by(id: akahu_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    family.akahu_items.active.ordered.find(&:credentials_configured?)
  end
  private_class_method :resolve_akahu_item
end
