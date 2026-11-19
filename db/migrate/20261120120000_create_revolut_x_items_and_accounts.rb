# frozen_string_literal: true

class CreateRevolutXItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :revolut_x_items, id: :uuid do |t|
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
      t.text :private_key
      t.datetime :transactions_synced_through

      t.timestamps
    end

    add_index :revolut_x_items, :status

    create_table :revolut_x_accounts, id: :uuid do |t|
      t.references :revolut_x_item, null: false, foreign_key: true, type: :uuid

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

    add_index :revolut_x_accounts,
              [ :revolut_x_item_id, :account_id ],
              unique: true,
              name: "index_revolut_x_accounts_on_item_and_account_id"
  end
end
