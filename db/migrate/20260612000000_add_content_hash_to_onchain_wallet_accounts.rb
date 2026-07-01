# frozen_string_literal: true

class AddContentHashToOnchainWalletAccounts < ActiveRecord::Migration[7.2]
  def change
    # Signature of the last sync's on-chain state (quantity + transaction set).
    # Lets the importer skip re-processing/re-materialization when nothing
    # on-chain has changed, so the value graph doesn't churn every sync.
    add_column :onchain_wallet_accounts, :content_hash, :string
  end
end
