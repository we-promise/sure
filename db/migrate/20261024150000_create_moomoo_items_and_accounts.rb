class CreateMoomooItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :moomoo_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.string :reauth_reason
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      # Public OAuth client registered for this connection, bound to one redirect URI.
      t.string :oauth_client_id
      t.string :oauth_redirect_uri
      t.string :oauth_registered_scope
      t.text :oauth_registration_access_token
      t.string :oauth_registration_client_uri
      # A client registered for a consent that hasn't finished yet; it takes
      # the place of the one above once that consent succeeds.
      t.jsonb :pending_oauth_client

      t.text :access_token
      t.text :refresh_token
      t.datetime :access_token_expires_at
      t.text :oauth_scope
      t.datetime :last_authorized_at
      t.datetime :last_token_refresh_at

      t.timestamps
    end

    add_index :moomoo_items, :status

    create_table :moomoo_accounts, id: :uuid do |t|
      t.references :moomoo_item, null: false, foreign_key: true, type: :uuid
      # A trading account that holds more than one currency becomes one row
      # per currency: the primary row, in the account's home currency, holds
      # moomoo's data, and each other currency's row points at it. Each
      # currency is a cash row and, when it has positions or trades, a stocks
      # row; an account that isn't split stays one combined row.
      t.references :primary_moomoo_account, type: :uuid, foreign_key: { to_table: :moomoo_accounts }
      t.string :role, null: false, default: "combined"
      t.string :name
      t.string :moomoo_account_id
      t.string :security_firm
      t.string :acc_type
      t.string :account_kind, default: "securities", null: false
      t.string :account_number_mask
      t.jsonb :enable_markets, default: [], null: false
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.jsonb :raw_account_payload, default: {}, null: false
      t.jsonb :raw_funds_payload, default: {}, null: false
      t.jsonb :raw_positions_payload, default: [], null: false
      t.jsonb :raw_fills_payload, default: [], null: false
      t.jsonb :raw_orders_payload, default: {}, null: false
      t.jsonb :raw_cash_logs_payload, default: [], null: false
      t.jsonb :history_cursors, default: {}, null: false
      t.datetime :cash_logs_synced_through
      t.datetime :cash_logs_backfilled_from
      # Logs a later sync left unread, which the backfill reads first.
      t.datetime :cash_logs_gap_from
      t.datetime :cash_logs_gap_until
      t.datetime :last_positions_sync
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :moomoo_accounts, [ :moomoo_item_id, :moomoo_account_id ],
      unique: true,
      where: "moomoo_account_id IS NOT NULL AND primary_moomoo_account_id IS NULL",
      name: "index_moomoo_accounts_on_item_and_account_id"
    add_index :moomoo_accounts, [ :moomoo_item_id, :moomoo_account_id, :currency, :role ],
      unique: true,
      where: "moomoo_account_id IS NOT NULL",
      name: "index_moomoo_accounts_on_item_account_id_currency_and_role"
  end
end
