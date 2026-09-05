# frozen_string_literal: true

class Provider::CoinspotAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("CoinspotAccount", self)

  # CoinSpot only supplies read-only exchange balances, so it can only back
  # the combined Crypto account type.
  def self.supported_account_types
    %w[Crypto]
  end

  # One connection card config per active, credentialed CoinSpot connection
  # the family has, for the account-linking UI. A single "connect CoinSpot"
  # card when none exist yet.
  def self.connection_configs(family:)
    return [] unless family.can_connect_coinspot?

    coinspot_items = family.coinspot_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return [ connection_config_for(nil) ] if coinspot_items.empty?

    coinspot_items.map { |coinspot_item| connection_config_for(coinspot_item) }
  end

  # Resolves and returns an authenticated Provider::Coinspot client for the
  # given family/connection, or nil if none is configured.
  def self.build_provider(family: nil, coinspot_item_id: nil)
    return nil unless family.present?

    coinspot_item = resolve_coinspot_item(family, coinspot_item_id)
    return nil unless coinspot_item&.credentials_configured?

    coinspot_item.coinspot_provider
  end

  def provider_name
    "coinspot"
  end

  # Path to trigger a manual sync of this account's connection.
  def sync_path
    return unless item

    Rails.application.routes.url_helpers.sync_coinspot_item_path(item)
  end

  # The CoinspotItem connection backing this account.
  def item
    provider_account.coinspot_item
  end

  # CoinSpot is read-only, so holdings it no longer reports are zeroed out
  # (see HoldingsProcessor#mark_absent_provider_holdings_zero!) rather than
  # deleted -- the provider adapter never deletes holdings itself.
  def can_delete_holdings?
    false
  end

  def institution_domain
    institution_metadata_value("domain")
  end

  def institution_name
    institution_metadata_value("name")
  end

  def institution_url
    institution_metadata_value("url")
  end

  def institution_color
    institution_metadata_value("color")
  end

  # Connection-card config for one CoinSpot connection (or the "connect new"
  # card when coinspot_item is nil): display name/description and the paths
  # for linking a new or existing account to it.
  def self.connection_config_for(coinspot_item)
    path_params = ->(extra = {}) do
      coinspot_item.present? ? extra.merge(coinspot_item_id: coinspot_item.id) : extra
    end

    {
      key: coinspot_item.present? ? "coinspot_#{coinspot_item.id}" : "coinspot",
      name: coinspot_item.present? ? I18n.t("coinspot_items.provider_connection.name", name: coinspot_item.name) : I18n.t("coinspot_items.provider_connection.default_name"),
      description: coinspot_item.present? ? I18n.t("coinspot_items.provider_connection.description", name: coinspot_item.name) : I18n.t("coinspot_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_coinspot_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_coinspot_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  # The CoinspotItem to act on: the one explicitly given by id, or the
  # family's single credentialed connection when there's exactly one and no
  # id was given. Returns nil when ambiguous (multiple connections, no id)
  # or the resolved item lacks configured credentials.
  def self.resolve_coinspot_item(family, coinspot_item_id)
    if coinspot_item_id.present?
      item = family.coinspot_items.active.credentials_configured.find_by(id: coinspot_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    credentialed_items = family.coinspot_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return credentialed_items.first if credentialed_items.one?

    nil
  end
  private_class_method :resolve_coinspot_item

  private

    # Institution metadata field, preferring the value cached on the account
    # (from its last import) and falling back to the live connection.
    def institution_metadata_value(key)
      metadata = provider_account.institution_metadata || {}
      metadata[key] || item&.public_send("institution_#{key}")
    end
end
