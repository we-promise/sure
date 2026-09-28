# frozen_string_literal: true

class CreatePluggyItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :pluggy_items, id: :uuid do |t|
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
      t.string :client_id
      t.string :client_secret

      t.timestamps
    end

    add_index :pluggy_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :pluggy_accounts, id: :uuid do |t|
      t.references :pluggy_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :pluggy_account_id
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

    # Scoped composite-unique index (per PluggyItem), not globally unique: the
    # same upstream Pluggy account id can legitimately recur across items when a
    # family re-connects or links the same bank account to a second PluggyItem,
    # and `PluggyAccount.upsert_from_pluggy!` does a single-column
    # find_or_initialize_by(pluggy_account_id:) that the global unique
    # constraint turns into a hard failure on those reconnections. The
    # non-unique single-column index preserves that lookup path; the composite
    # unique index enforces per-item uniqueness instead of global. NULLs are
    # distinct under PostgreSQL unique indexes, so unlinked rows (null
    # pluggy_account_id) coexist without collision. Mirrors the redbark /
    # questrade / ibkr / trading212 composite-unique account-id index pattern.
    add_index :pluggy_accounts, :pluggy_account_id
    add_index :pluggy_accounts, [ :pluggy_item_id, :pluggy_account_id ],
              unique: true,
              name: "index_pluggy_accounts_on_item_and_account_id"
  end
end
