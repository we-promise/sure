# frozen_string_literal: true

class CreateTricountItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :tricount_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      # Institution metadata
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      # Status and lifecycle
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false

      # Sync settings
      t.datetime :sync_start_date

      # Raw data storage
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      # Provider-specific credential fields
      t.text :sharing_tokens
      t.text :session_token
      t.string :app_installation_uuid
      t.text :client_public_key
      t.string :tricount_user_id

      t.timestamps
    end

    add_index :tricount_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :tricount_accounts, id: :uuid do |t|
      t.references :tricount_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :tricount_account_id
      t.string :account_number

      # Account details
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      # The member of the tricount whose position the account follows
      t.string :member_uuid
      # Payments the member divided into parts, each paired with its own card
      # or bank charge: { entry uuid => ["60.00", "40.00"] }
      t.jsonb :paid_splits, null: false, default: {}

      # Sync settings
      t.date :sync_start_date

      t.timestamps
    end

    # A tricount is shared: several families can each follow the same one.
    add_index :tricount_accounts, [ :tricount_item_id, :tricount_account_id ], unique: true
  end
end
