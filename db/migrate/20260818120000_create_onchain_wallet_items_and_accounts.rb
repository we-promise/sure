# frozen_string_literal: true

class CreateOnchainWalletItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Family-level connection. One item groups every self-custody address a
    # family tracks; addresses live on onchain_wallet_accounts so a future
    # extended-key (xpub) wallet can add its derived addresses as extra rows
    # without changing any column or index defined here.
    create_table :onchain_wallet_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false

      t.datetime :sync_start_date

      # Optional per-family explorer credential. Every chain works keyless; a
      # key only raises Ethereum's rate limit.
      t.text :etherscan_api_key

      t.timestamps
    end

    add_index :onchain_wallet_items, :status

    # One row per tracked asset, per address, per chain.
    create_table :onchain_wallet_accounts, id: :uuid do |t|
      t.references :onchain_wallet_item, null: false, foreign_key: true, type: :uuid

      t.string :chain, null: false
      t.string :wallet_address, null: false
      t.string :asset_kind, null: false
      t.string :contract_address

      t.string :symbol, null: false
      t.string :name
      t.integer :decimals, null: false, default: 0

      # Quantities are chain-native: 18 decimals covers every ERC-20 we can see.
      t.decimal :quantity, precision: 32, scale: 18, default: 0, null: false
      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4

      # Digest of the on-chain state last processed. Equal digests mean the
      # chain has not moved, which is how the syncer stays idempotent.
      t.string :content_hash

      t.jsonb :raw_payload
      t.jsonb :raw_movements_payload
      t.jsonb :extra, default: {}, null: false

      t.timestamps

      # A token is identified by its contract, and the partial unique indexes
      # below key on it — but NULLs are distinct to Postgres, so a token row that
      # reached the table without one would slip past its index and duplicate.
      # The model enforces this as well; a direct write does not go through it.
      t.check_constraint "asset_kind = 'native' OR contract_address IS NOT NULL",
                         name: "chk_onchain_wallet_accounts_token_has_contract"

      # The partial unique indexes below name their kind, so a row carrying any
      # other one is keyed by nothing and duplicates freely. Adding a token kind
      # already means adding its index here; this keeps the table from silently
      # accepting rows for one that has none.
      t.check_constraint "asset_kind IN ('native', 'erc20', 'spl')",
                         name: "chk_onchain_wallet_accounts_known_asset_kind"
    end

    add_index :onchain_wallet_accounts, [ :onchain_wallet_item_id, :chain, :wallet_address ],
              name: "index_onchain_wallet_accounts_on_item_and_address"

    # One partial unique index per asset kind, because the identity of an asset
    # differs by kind: a native coin is identified by its address alone, while a
    # token is identified by its contract/mint. A single index over all columns
    # would treat two native rows with NULL contract_address as distinct and let
    # duplicates through.
    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address ],
              unique: true,
              where: "asset_kind = 'native'",
              name: "index_onchain_wallet_accounts_unique_native"

    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address, :contract_address ],
              unique: true,
              where: "asset_kind = 'erc20'",
              name: "index_onchain_wallet_accounts_unique_erc20"

    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address, :contract_address ],
              unique: true,
              where: "asset_kind = 'spl'",
              name: "index_onchain_wallet_accounts_unique_spl"
  end
end
