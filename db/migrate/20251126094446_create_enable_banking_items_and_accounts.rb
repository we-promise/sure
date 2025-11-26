class CreateEnableBankingItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :enable_banking_items, id: :uuid do |t|
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
      t.string :country_code
      t.string :application_id
      t.text :client_certificate

      # OAuth session fields
      t.string :session_id
      t.datetime :session_expires_at
      t.string :aspsp_name  # Bank/ASPSP name
      t.string :aspsp_id    # Bank/ASPSP identifier

      # Authorization flow fields (temporary, cleared after session created)
      t.string :authorization_id

      t.timestamps
    end

    add_index :enable_banking_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :enable_banking_accounts, id: :uuid do |t|
      t.references :enable_banking_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :account_id

      # Account details
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider
      t.string :iban
      t.string :uid  # Enable Banking unique identifier

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :enable_banking_accounts, :account_id
  end
end
