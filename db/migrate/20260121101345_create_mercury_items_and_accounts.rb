class CreateMercuryItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :mercury_items, id: :uuid do |t|
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
      t.text :token
      t.string :base_url

      t.timestamps
    end

    add_index :mercury_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :mercury_accounts, id: :uuid do |t|
      t.references :mercury_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :account_id, null: false

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

      t.timestamps
    end

    add_index :mercury_accounts, :account_id, unique: true
  end
end
