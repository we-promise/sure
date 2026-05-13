# frozen_string_literal: true

class CreateKrakenItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :kraken_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      t.datetime :sync_start_date
      t.jsonb :raw_payload

      t.text :api_key
      t.text :api_secret
      t.bigint :last_nonce, default: 0, null: false

      t.timestamps
    end

    add_index :kraken_items, :status

    create_table :kraken_accounts, id: :uuid do |t|
      t.references :kraken_item, null: false, foreign_key: true, type: :uuid

      t.string :name
      t.string :account_id, null: false
      t.string :account_type
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.jsonb :extra, default: {}, null: false

      t.timestamps
    end

    add_index :kraken_accounts, :account_type
    add_index :kraken_accounts,
              [ :kraken_item_id, :account_id ],
              unique: true,
              name: "index_kraken_accounts_on_item_and_account_id"
  end
end
