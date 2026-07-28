# frozen_string_literal: true

class CreateWiseItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :wise_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid

      t.string :profile_id, null: false
      t.string :profile_type, null: false
      t.string :name, null: false

      t.string :status, null: false, default: "good"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.boolean :pending_account_setup, null: false, default: false

      t.datetime :sync_start_date

      t.text :token, null: false
      t.jsonb :raw_payload

      t.timestamps
    end

    add_index :wise_items, :status
    add_index :wise_items, [ :family_id, :profile_id ], unique: true

    create_table :wise_accounts, id: :uuid do |t|
      t.references :wise_item, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.string :balance_id, null: false
      t.string :currency, null: false
      t.string :name

      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :reserved_balance, precision: 19, scale: 4

      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :wise_accounts, [ :wise_item_id, :balance_id ], unique: true
  end
end
