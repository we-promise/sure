class Provider::OpenBankingIoAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("OpenBankingIoAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_open_banking_io?

    family.open_banking_io_items.active.ordered.select(&:credentials_configured?).map do |open_banking_io_item|
      connection_config_for(open_banking_io_item)
    end
  end

  def self.build_provider(family: nil, open_banking_io_item_id: nil)
    return nil unless family.present?

    open_banking_io_item = resolve_open_banking_io_item(family, open_banking_io_item_id)
    return nil unless open_banking_io_item&.credentials_configured?

    Provider::OpenBankingIo.new(
      api_base_url: open_banking_io_item.api_base_url,
      api_key: open_banking_io_item.api_key,
      private_key: open_banking_io_item.private_key
    )
  end

  def self.connection_config_for(open_banking_io_item)
    path_params = ->(extra = {}) { extra.merge(open_banking_io_item_id: open_banking_io_item.id) }

    {
      key: "open_banking_io_#{open_banking_io_item.id}",
      name: open_banking_io_item.name.presence || I18n.t("providers.open_banking_io.name"),
      description: I18n.t("providers.open_banking_io.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_open_banking_io_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_open_banking_io_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def provider_name
    "open_banking_io"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_open_banking_io_item_path(item)
  end

  def item
    provider_account.open_banking_io_item
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

  def self.resolve_open_banking_io_item(family, open_banking_io_item_id)
    if open_banking_io_item_id.present?
      item = family.open_banking_io_items.active.find_by(id: open_banking_io_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    family.open_banking_io_items.active.ordered.find(&:credentials_configured?)
  end
  private_class_method :resolve_open_banking_io_item
end
