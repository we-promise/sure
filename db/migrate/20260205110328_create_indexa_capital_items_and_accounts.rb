# frozen_string_literal: true

class CreateIndexaCapitalItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :indexa_capital_items, id: :uuid do |t|
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
      t.string :username
      t.string :document
      t.text :password

      t.timestamps
    end

    add_index :indexa_capital_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :indexa_capital_accounts, id: :uuid do |t|
      t.references :indexa_capital_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :indexa_capital_account_id
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

      # Investment-specific columns
      t.string :indexa_capital_authorization_id
      t.decimal :cash_balance, precision: 19, scale: 4, default: 0.0
      t.jsonb :raw_holdings_payload, default: []
      t.jsonb :raw_activities_payload, default: []
      t.datetime :last_holdings_sync
      t.datetime :last_activities_sync
      t.boolean :activities_fetch_pending, default: false

      # Sync settings
      t.date :sync_start_date

      t.timestamps
    end

    add_index :indexa_capital_accounts, :indexa_capital_account_id, unique: true
    add_index :indexa_capital_accounts, :indexa_capital_authorization_id
  end
end
