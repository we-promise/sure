class CreateSaxoConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :saxo_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false, default: "Saxo"
      t.string :status, null: false, default: "good"
      t.text :access_token
      t.text :refresh_token
      t.datetime :access_expires_at
      t.datetime :refresh_expires_at
      t.string :application_key_digest
      t.string :redirect_uri
      t.date :sync_start_date, null: false, default: "2010-01-01"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.boolean :pending_account_setup, null: false, default: true
      t.timestamps
    end

    create_table :saxo_accounts, id: :uuid do |t|
      t.references :saxo_item, type: :uuid, null: false, foreign_key: true
      t.string :account_id, null: false
      t.string :name, null: false
      t.string :currency, null: false
      t.string :account_type
      t.date :opening_date
      t.decimal :current_balance, precision: 24, scale: 8
      t.decimal :cash_balance, precision: 24, scale: 8
      t.text :raw_payload
      t.text :raw_holdings_payload
      t.text :raw_transactions_payload
      t.date :history_synced_on
      t.timestamps
    end
    add_index :saxo_accounts, [ :saxo_item_id, :account_id ], unique: true

    create_table :saxo_authorizations, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :saxo_item, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :state_digest, null: false
      t.string :redirect_uri, null: false
      t.string :application_key_digest, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :saxo_authorizations, :state_digest, unique: true
    add_index :saxo_authorizations, :expires_at
  end
end
