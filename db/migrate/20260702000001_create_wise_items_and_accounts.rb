# frozen_string_literal: true

class CreateWiseItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :wise_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      # Institution metadata
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url

      # Status and lifecycle
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      # Sync settings
      t.datetime :sync_start_date

      # Raw data storage
      t.jsonb :raw_payload

      # Provider-specific credential — personal API token from Wise settings
      t.text :api_token

      t.timestamps
    end

    add_index :wise_items, :status

    create_table :wise_accounts, id: :uuid do |t|
      t.references :wise_item, null: false, foreign_key: true, type: :uuid

      # Account identification — balance ID from Wise, plus the owning profile
      t.string :wise_account_id
      t.string :wise_profile_id

      # Account details
      t.string :name
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_type

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload

      # Transaction history
      t.jsonb :raw_transactions_payload, default: []
      t.datetime :last_transactions_sync

      # Sync settings
      t.date :sync_start_date

      t.timestamps
    end

    add_index :wise_accounts, [ :wise_item_id, :wise_account_id ], unique: true
    add_index :wise_accounts, :wise_profile_id
  end
end
