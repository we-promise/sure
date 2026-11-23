# frozen_string_literal: true

class CreateEmailAlertItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :email_alert_items, id: :uuid do |t|
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

      # Secret path segment of the inbound webhook URL (deterministically
      # encrypted so it can be looked up).
      t.string :inbound_token, null: false

      t.timestamps
    end

    add_index :email_alert_items, :status
    add_index :email_alert_items, :inbound_token, unique: true

    create_table :email_alert_accounts, id: :uuid do |t|
      t.references :email_alert_item, null: false, foreign_key: true, type: :uuid

      t.string :name
      # "<parser key>:<account identifier>", e.g. "gtbank:4821" or "grey:usd"
      t.string :email_alert_account_id, null: false
      t.string :account_number

      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.datetime :balance_as_of
      t.string :account_status
      t.string :account_type
      t.string :provider

      t.jsonb :institution_metadata
      t.jsonb :raw_payload

      t.date :sync_start_date

      t.timestamps
    end

    add_index :email_alert_accounts, [ :email_alert_item_id, :email_alert_account_id ],
              unique: true, name: "index_email_alert_accounts_on_item_and_account_id"

    create_table :email_alert_messages, id: :uuid do |t|
      t.references :email_alert_item, null: false, foreign_key: true, type: :uuid
      t.references :email_alert_account, foreign_key: true, type: :uuid

      # SHA-256 of the Message-ID (or of the raw message when it has none)
      t.string :fingerprint, null: false
      t.text :raw_base64, null: false
      t.string :from_address
      t.string :subject
      t.string :status, null: false, default: "pending"
      t.text :parsed_payload
      t.text :processing_error
      t.datetime :received_at, null: false
      t.datetime :processed_at

      t.timestamps
    end

    add_index :email_alert_messages, [ :email_alert_item_id, :fingerprint ], unique: true
    add_index :email_alert_messages, [ :email_alert_item_id, :status ]
  end
end
