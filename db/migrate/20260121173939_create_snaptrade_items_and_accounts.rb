class CreateSnaptradeItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :snaptrade_items, id: :uuid, if_not_exists: true do |t|
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
      t.datetime :last_synced_at

      # Raw data storage
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      # Provider-specific credential fields
      t.string :client_id
      t.string :consumer_key
      t.string :snaptrade_user_id
      t.string :snaptrade_user_secret

      t.timestamps
    end

    add_index :snaptrade_items, :status unless index_exists?(:snaptrade_items, :status)

    # Create provider accounts table (stores individual account data from provider)
    create_table :snaptrade_accounts, id: :uuid, if_not_exists: true do |t|
      t.references :snaptrade_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name

      # SnapTrade-specific IDs (snaptrade_account_id is SnapTrade's UUID for this account)
      t.string :snaptrade_account_id
      t.string :snaptrade_authorization_id
      t.string :account_number
      t.string :brokerage_name

      # Account details
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.jsonb :raw_holdings_payload, default: []
      t.jsonb :raw_activities_payload, default: []

      # Sync tracking
      t.datetime :last_holdings_sync
      t.datetime :last_activities_sync
      t.boolean :activities_fetch_pending, default: false

      t.timestamps
    end

    unless index_exists?(:snaptrade_accounts, :snaptrade_account_id)
      add_index :snaptrade_accounts, :snaptrade_account_id, unique: true
    end
  end
end
