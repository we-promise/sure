# frozen_string_literal: true

class CreateRedbarkItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :redbark_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false

      # Institution metadata
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      # Status and lifecycle
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      # Sync settings
      t.datetime :sync_start_date

      # Raw data storage
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      # Provider-specific credential fields
      t.text :api_key, null: false

      t.timestamps
    end

    add_index :redbark_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :redbark_accounts, id: :uuid do |t|
      t.references :redbark_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name, null: false
      t.string :redbark_account_id, null: false
      t.string :connection_id
      t.string :account_number

      # Account details
      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      # Setup state - accounts the user chose to skip stay hidden from setup prompts
      t.boolean :ignored, default: false, null: false

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      # Sync settings
      t.date :sync_start_date

      t.timestamps
    end

    add_index :redbark_accounts, [ :redbark_item_id, :redbark_account_id ], unique: true, name: "index_redbark_accounts_on_item_and_account_id"
  end
end
