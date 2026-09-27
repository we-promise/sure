# frozen_string_literal: true

class Provider::BitcoinWalletAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("BitcoinWalletAccount", self)

  def provider_name
    "onchain_wallet"
  end

  def item
    provider_account.onchain_wallet_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_account_bitcoin_wallet_path(account)
  end

  def institution_name
    "Bitcoin"
  end

  def logo_url
    Security.brandfetch_crypto_url("BTC")
  end

  def raw_payload
    { quantity: provider_account.quantity.to_s("F") }
  end
end
