# frozen_string_literal: true

class Provider::FioAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("FioAccount", self)

  # Fio's statement header carries no account type, so the user picks one during setup.
  # Current and savings accounts are Depository; a token issued for a mortgage, loan or
  # overdraft account is a Loan, whose balance Fio reports negative (see
  # FioAccount::Processor#update_account_balance).
  def self.supported_account_types
    %w[Depository Loan]
  end

  # Connection config hashes for each of the family's configured Fio items. One item per
  # token, and a token reaches exactly one account, so a family with three Fio accounts
  # has three items.
  def self.connection_configs(family:)
    return [] unless family.can_connect_fio?

    family.fio_items.active.ordered.select(&:credentials_configured?).map do |fio_item|
      connection_config_for(fio_item)
    end
  end

  # Build a Fio API client for the resolved item, or nil if none is usable.
  def self.build_provider(family: nil, fio_item_id: nil)
    return nil unless family.present?

    fio_item = resolve_fio_item(family, fio_item_id)
    return nil unless fio_item&.credentials_configured?

    Provider::Fio.new(fio_item.token)
  end

  # Build the settings connection-config hash for a single Fio item.
  def self.connection_config_for(fio_item)
    path_params = ->(extra = {}) { extra.merge(fio_item_id: fio_item.id) }

    {
      key: "fio_#{fio_item.id}",
      name: fio_item.name.presence || I18n.t("providers.fio.name"),
      description: I18n.t("providers.fio.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_fio_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_fio_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  # Provider key used across the sync/account-provider machinery.
  def provider_name
    "fio"
  end

  # Route to trigger a manual sync for this provider account's item.
  def sync_path
    Rails.application.routes.url_helpers.sync_fio_item_path(item)
  end

  # The FioItem backing this provider account.
  def item
    provider_account.fio_item
  end

  # Fio reports no holdings.
  def can_delete_holdings?
    false
  end

  def institution_domain
    provider_account.institution_metadata&.dig("domain") || item&.institution_domain
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") || item&.institution_name
  end

  def institution_url
    provider_account.institution_metadata&.dig("url") || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end

  # Resolve the target Fio item.
  #
  # A requested id is authoritative: unlike an aggregator, where one item covers every
  # account, a Fio item is one token for one account, so a family routinely has several.
  # Falling back to another connection would silently build a client for the wrong
  # account. Only an absent id picks the first configured connection.
  def self.resolve_fio_item(family, fio_item_id)
    if fio_item_id.present?
      item = family.fio_items.active.find_by(id: fio_item_id)
      return item&.credentials_configured? ? item : nil
    end

    family.fio_items.active.ordered.find(&:credentials_configured?)
  end
  private_class_method :resolve_fio_item
end
