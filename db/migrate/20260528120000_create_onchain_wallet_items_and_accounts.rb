# frozen_string_literal: true

class CreateOnchainWalletItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :onchain_wallet_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false

      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.datetime :sync_start_date
      t.jsonb :raw_payload

      t.text :etherscan_api_key

      t.timestamps
    end

    add_index :onchain_wallet_items, :status

    create_table :onchain_wallet_accounts, id: :uuid do |t|
      t.references :onchain_wallet_item, null: false, foreign_key: true, type: :uuid

      t.string :chain, null: false
      t.string :wallet_address, null: false
      t.string :asset_kind, default: "native", null: false
      t.string :token_contract
      t.string :symbol, null: false
      t.string :name, null: false
      t.integer :decimals, default: 18, null: false

      t.string :currency, default: "USD", null: false
      t.decimal :quantity, precision: 32, scale: 18, default: 0, null: false
      t.decimal :current_balance, precision: 19, scale: 4, default: 0, null: false

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.jsonb :extra, default: {}, null: false

      t.timestamps
    end

    add_index :onchain_wallet_accounts, :chain
    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address, :asset_kind, :symbol ],
              unique: true,
              where: "asset_kind = 'native'",
              name: "index_onchain_wallet_accounts_unique_native"
    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address, :asset_kind, :token_contract, :symbol ],
              unique: true,
              where: "asset_kind = 'erc20'",
              name: "index_onchain_wallet_accounts_unique_token"
  end
end
