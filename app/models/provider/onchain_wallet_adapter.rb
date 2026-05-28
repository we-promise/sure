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

    [ {
      key: "onchain_wallet",
      name: "On-chain Wallets",
      description: "Connect Bitcoin and Ethereum wallet addresses",
      can_connect: true,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.new_wallet_onchain_wallet_items_path
      },
      existing_account_path: nil
    } ]
  end

  def provider_name
    "onchain_wallet"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_onchain_wallet_item_path(item)
  end

  def item
    provider_account.onchain_wallet_item
  end

  def can_delete_holdings?
    false
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") || item&.institution_display_name
  end

  def institution_domain
    item&.institution_domain
  end

  def institution_url
    item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
