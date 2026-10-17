# frozen_string_literal: true

class CreateGocardlessItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :gocardless_items, id: :uuid do |t|
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

      # Provider-specific credential fields.
      # institution_id / institution_name are NOT repeated here: the shared institution
      # metadata block above already defines them, and redeclaring them aborts the
      # migration with "already defined column".
      t.string :secret_id
      t.text :secret_key

      # GoCardless connection state. A requisition is one user consent against one
      # institution, and it is the handle used to read accounts; the agreement pins how
      # much history and how long an access window that consent carries.
      t.string :requisition_id
      t.string :agreement_id
      t.string :requisition_status

      t.timestamps
    end

    add_index :gocardless_items, :status
    add_index :gocardless_items, :requisition_id, unique: true

    # Create provider accounts table (stores individual account data from provider)
    create_table :gocardless_accounts, id: :uuid do |t|
      t.references :gocardless_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :gocardless_account_id
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

      # Sync settings
      t.date :sync_start_date

      t.timestamps
    end

    add_index :gocardless_accounts, :gocardless_account_id, unique: true
  end
end
