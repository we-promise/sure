# frozen_string_literal: true

class CreateTruelayerItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    # One row per TrueLayer bank connection (one consent). The app credentials
    # are copied onto every connection, as Enable Banking does, so each one is
    # self-contained.
    create_table :truelayer_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false
      t.datetime :sync_start_date

      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      # TrueLayer app credentials
      t.string :client_id
      t.text :client_secret

      # OAuth tokens for this connection
      t.text :access_token
      t.text :refresh_token
      t.datetime :access_token_expires_at
      t.datetime :consent_expires_at
      # When the user last completed TrueLayer's consent dialog. UK banks only
      # release more than 90 days of history in the few minutes after it.
      t.datetime :last_authorized_at
      # When the post-consent history backfill finished for every account.
      t.datetime :history_backfilled_at
      t.string :reauth_reason

      t.timestamps
    end

    add_index :truelayer_items, :status

    create_table :truelayer_accounts, id: :uuid do |t|
      t.references :truelayer_item, null: false, foreign_key: true, type: :uuid

      t.string :name
      t.string :account_id
      # "account" (current/savings, /data/v1/accounts) or "card" (/data/v1/cards)
      t.string :account_kind, null: false, default: "account"
      t.string :account_type
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :provider

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :truelayer_accounts, [ :truelayer_item_id, :account_id ], unique: true, where: "account_id IS NOT NULL"
    add_index :truelayer_accounts, :account_id
  end
end
