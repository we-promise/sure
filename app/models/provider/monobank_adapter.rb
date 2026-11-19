class Provider::MonobankAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("MonobankAccount", self)

  # Sure accountable types that can be created from Monobank accounts. Everything the
  # personal API exposes — cards and jars alike — is a cash account (see
  # MonobankAccount::MONOBANK_ACCOUNT_TYPE_MAP).
  def self.supported_account_types
    %w[Depository]
  end

  # Connection config hashes for each of the family's configured Monobank items.
  def self.connection_configs(family:)
    return [] unless family.can_connect_monobank?

    family.monobank_items.active.ordered.select(&:credentials_configured?).map do |monobank_item|
      connection_config_for(monobank_item)
    end
  end

  # Build a Monobank API client for the resolved item, or nil if none is usable.
  def self.build_provider(family: nil, monobank_item_id: nil)
    return nil unless family.present?

    monobank_item = resolve_monobank_item(family, monobank_item_id)
    return nil unless monobank_item&.credentials_configured?

    Provider::Monobank.new(monobank_item.access_token)
  end

  # Build the settings connection-config hash for a single Monobank item.
  def self.connection_config_for(monobank_item)
    path_params = ->(extra = {}) { extra.merge(monobank_item_id: monobank_item.id) }

    {
      key: "monobank_#{monobank_item.id}",
      name: monobank_item.name.presence || I18n.t("providers.monobank.name"),
      description: I18n.t("providers.monobank.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_monobank_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_monobank_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  # Provider key used across the sync/account-provider machinery.
  def provider_name
    "monobank"
  end

  # Route to trigger a manual sync for this provider account's item.
  def sync_path
    Rails.application.routes.url_helpers.sync_monobank_item_path(item)
  end

  # The MonobankItem backing this provider account.
  def item
    provider_account.monobank_item
  end

  # Monobank holdings are never deletable by the sync machinery.
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

  # Resolve the target Monobank item: the requested one, else the first configured.
  def self.resolve_monobank_item(family, monobank_item_id)
    if monobank_item_id.present?
      item = family.monobank_items.active.find_by(id: monobank_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    family.monobank_items.active.ordered.find(&:credentials_configured?)
  end
  private_class_method :resolve_monobank_item
end
