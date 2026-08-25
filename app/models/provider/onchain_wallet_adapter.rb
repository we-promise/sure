# frozen_string_literal: true

class Provider::OnchainWalletAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("OnchainWalletAccount", self)

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_onchain_wallet?

    [
      {
        key: "onchain_wallet",
        name: I18n.t("onchain_wallet_items.provider_connection.name"),
        description: I18n.t("onchain_wallet_items.provider_connection.description"),
        can_connect: true,
        new_account_path: ->(accountable_type, return_to) {
          Rails.application.routes.url_helpers.new_wallet_onchain_wallet_items_path(
            accountable_type: accountable_type,
            return_to: return_to
          )
        }
      }
    ]
  end

  def provider_name
    "onchain_wallet"
  end

  def sync_path
    return unless item

    Rails.application.routes.url_helpers.sync_onchain_wallet_item_path(item)
  end

  def item
    provider_account.onchain_wallet_item
  end

  # On-chain balances are derived entirely from what the chain reports, so a
  # holding that disappears from a snapshot is set to zero rather than deleted.
  def can_delete_holdings?
    false
  end

  # There is no institution behind a self-custody wallet; the chain is the
  # closest thing to one.
  def institution_name
    provider_account.chain_label
  end
end
