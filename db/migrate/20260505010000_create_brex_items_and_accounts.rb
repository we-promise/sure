# frozen_string_literal: true

class CreateBrexItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :brex_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false

      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, null: false, default: "good"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.boolean :pending_account_setup, null: false, default: false

      t.datetime :sync_start_date

      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      t.text :token, null: false
      t.string :base_url

      t.timestamps
    end

    add_index :brex_items, :status

    create_table :brex_accounts, id: :uuid do |t|
      t.references :brex_item, null: false, foreign_key: true, type: :uuid

      t.string :name
      t.string :account_id, null: false
      t.string :account_kind, null: false, default: "cash"

      t.string :currency, null: false, default: "USD"
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.decimal :account_limit, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :brex_accounts,
              [ :brex_item_id, :account_id ],
              unique: true,
              name: "index_brex_accounts_on_item_and_account_id"
  end
end
