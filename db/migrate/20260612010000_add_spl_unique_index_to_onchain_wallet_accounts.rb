# frozen_string_literal: true

class AddSplUniqueIndexToOnchainWalletAccounts < ActiveRecord::Migration[7.2]
  def change
    # Mirror the erc20 partial unique index for Solana SPL token accounts so
    # duplicate logical rows can't be created under concurrency.
    add_index :onchain_wallet_accounts,
              %i[onchain_wallet_item_id chain wallet_address asset_kind token_contract symbol],
              unique: true,
              where: "((asset_kind)::text = 'spl'::text)",
              name: "index_onchain_wallet_accounts_unique_spl"
  end
end
