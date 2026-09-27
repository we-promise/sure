# frozen_string_literal: true

class Provider::BitcoinWalletAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("BitcoinWalletAccount", self)

  # Group this position under the existing on-chain connection in provider UI.
  def provider_name
    "onchain_wallet"
  end

  # Return the family's on-chain connection owning this tracking record.
  def item
    provider_account.onchain_wallet_item
  end

  # Route manual refreshes through the account-scoped wallet authorization gate.
  def sync_path
    Rails.application.routes.url_helpers.sync_account_bitcoin_wallet_path(account)
  end

  # Identify the tracked network in shared institution metadata.
  def institution_name
    "Bitcoin"
  end

  # Use the existing crypto logo resolver for the BTC position's branding.
  def logo_url
    Security.brandfetch_crypto_url("BTC")
  end

  # Expose a decimal quantity for diagnostics without keys or address lists.
  def raw_payload
    { quantity: provider_account.quantity.to_s("F") }
  end
end
