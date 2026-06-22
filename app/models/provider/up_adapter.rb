class Provider::UpAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("UpAccount", self)

  # Sure accountable types that can be created from Up accounts.
  def self.supported_account_types
    %w[Depository Loan]
  end

  # Connection config hashes for each of the family's configured Up items.
  def self.connection_configs(family:)
    return [] unless family.can_connect_up?

    family.up_items.active.ordered.select(&:credentials_configured?).map do |up_item|
      connection_config_for(up_item)
    end
  end

  # Build an Up API client for the resolved item, or nil if none is usable.
  def self.build_provider(family: nil, up_item_id: nil)
    return nil unless family.present?

    up_item = resolve_up_item(family, up_item_id)
    return nil unless up_item&.credentials_configured?

    Provider::Up.new(up_item.access_token)
  end

  # Build the settings connection-config hash for a single Up item.
  def self.connection_config_for(up_item)
    path_params = ->(extra = {}) { extra.merge(up_item_id: up_item.id) }

    {
      key: "up_#{up_item.id}",
      name: up_item.name.presence || I18n.t("providers.up.name"),
      description: I18n.t("providers.up.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_up_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_up_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  # Provider key used across the sync/account-provider machinery.
  def provider_name
    "up"
  end

  # Route to trigger a manual sync for this provider account's item.
  def sync_path
    Rails.application.routes.url_helpers.sync_up_item_path(item)
  end

  # The UpItem backing this provider account.
  def item
    provider_account.up_item
  end

  # Up holdings are never deletable by the sync machinery.
  def can_delete_holdings?
    false
  end

  # Institution domain from account metadata, or nil.
  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["domain"]
  end

  # Institution name from account metadata, falling back to the item's.
  def institution_name
    metadata = provider_account.institution_metadata
    metadata&.dig("name").presence || item&.institution_name
  end

  # Institution URL from account metadata, falling back to the item's.
  def institution_url
    metadata = provider_account.institution_metadata
    metadata&.dig("url").presence || item&.institution_url
  end

  # Brand color for the institution, from the item.
  def institution_color
    item&.institution_color
  end

  # Resolve the target Up item: the requested one, else the first configured.
  def self.resolve_up_item(family, up_item_id)
    if up_item_id.present?
      item = family.up_items.active.find_by(id: up_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    family.up_items.active.ordered.find(&:credentials_configured?)
  end
  private_class_method :resolve_up_item
end
