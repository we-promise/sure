class CreateBitcoinWalletAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :bitcoin_wallet_accounts, id: :uuid do |t|
      t.references :onchain_wallet_item, null: false, type: :uuid, foreign_key: true
      t.references :account, null: false, type: :uuid, foreign_key: true, index: { unique: true }
      t.references :security, null: false, type: :uuid, foreign_key: true
      t.string :status, null: false, default: "discovering"
      t.bigint :balance_sats, null: false, default: 0
      t.bigint :baseline_sats
      t.decimal :baseline_cash_balance, precision: 19, scale: 4
      t.boolean :needs_reconciliation, null: false, default: false
      t.integer :baseline_block_height
      t.datetime :baseline_at
      t.datetime :last_synced_at
      t.boolean :history_truncated, null: false, default: false
      t.string :last_error
      t.timestamps
    end

    create_table :bitcoin_wallet_sources, id: :uuid do |t|
      t.references :bitcoin_wallet_account, null: false, type: :uuid, foreign_key: true
      t.string :kind, null: false
      t.text :extended_public_key
      t.string :fingerprint, null: false
      t.string :receive_address, null: false
      t.integer :gap_limit, null: false, default: 20
      t.jsonb :discovery, null: false, default: {}
      t.timestamps
      t.index [ :bitcoin_wallet_account_id, :fingerprint ], unique: true, name: "index_bitcoin_sources_on_wallet_and_fingerprint"
      t.check_constraint "kind IN ('address', 'bip84')", name: "bitcoin_source_kind"
      t.check_constraint "gap_limit BETWEEN 20 AND 1000", name: "bitcoin_source_gap_limit"
    end

    create_table :bitcoin_wallet_addresses, id: :uuid do |t|
      t.references :bitcoin_wallet_account, null: false, type: :uuid, foreign_key: true
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.references :bitcoin_wallet_source, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :address, null: false
      t.integer :branch
      t.integer :address_index
      t.boolean :used, null: false, default: false
      t.timestamps
      t.index [ :bitcoin_wallet_account_id, :address ], unique: true, name: "index_bitcoin_addresses_on_wallet_and_address"
      t.index :address
      t.index [ :family_id, :address ], unique: true
    end

    create_table :bitcoin_wallet_transactions, id: :uuid do |t|
      t.references :bitcoin_wallet_account, null: false, type: :uuid, foreign_key: true
      t.string :txid, null: false
      t.bigint :amount_sats, null: false
      t.boolean :confirmed, null: false, default: false
      t.boolean :present, null: false, default: true
      t.boolean :baseline, null: false, default: false
      t.integer :block_height
      t.datetime :occurred_at, null: false
      t.datetime :removed_at
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
      t.index [ :bitcoin_wallet_account_id, :txid ], unique: true, name: "index_bitcoin_transactions_on_wallet_and_txid"
    end
  end
end
