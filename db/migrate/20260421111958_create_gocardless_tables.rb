class CreateGocardlessTables < ActiveRecord::Migration[7.2]
  def change
    create_table :gocardless_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid

      # Institution metadata
      t.string :name
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      # GoCardless requisition / agreement
      t.string   :requisition_id
      t.string   :agreement_id
      t.datetime :agreement_expires_at

      # OAuth tokens (encrypted at rest via AR Encryption)
      t.text     :access_token
      t.text     :refresh_token
      t.datetime :access_token_expires_at

      # Status and lifecycle
      t.string  :status,                  default: "good"
      t.string  :sync_frequency,          default: "manual", null: false
      t.boolean :scheduled_for_deletion,  default: false
      t.boolean :pending_account_setup,   default: false
      t.datetime :sync_start_date

      # Raw API payloads
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      t.timestamps
    end

    add_index :gocardless_items, :status
    add_index :gocardless_items, :requisition_id

    create_table :gocardless_accounts, id: :uuid do |t|
      t.references :gocardless_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string  :name
      t.string  :account_id
      t.string  :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string  :account_status
      t.string  :account_type
      t.string  :provider

      # Whether the user skipped linking this account during setup
      t.boolean :skipped, default: false, null: false

      # Metadata and raw API payloads
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :gocardless_accounts, :account_id
    add_index :gocardless_accounts, :skipped
  end
end
