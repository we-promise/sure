# frozen_string_literal: true

class CreateFioItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :fio_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      t.date :sync_start_date

      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      t.text :token

      t.timestamps
    end

    add_index :fio_items, :status

    create_table :fio_accounts, id: :uuid do |t|
      t.references :fio_item, null: false, foreign_key: true, type: :uuid

      # A Fio token grants access to exactly one account, so these are the statement
      # header fields rather than anything chosen by the user.
      t.string :name, null: false
      t.string :fio_account_id
      t.string :bank_id
      t.string :iban
      t.string :bic

      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4

      t.boolean :ignored, default: false, null: false

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.date :sync_start_date
      # Last day already covered by a statement request. The next sync re-reads a few
      # days before it (see FIO_SYNC_LOOKBACK_DAYS) because Fio assigns a movement its
      # booking date, which can land behind the day it becomes visible.
      t.date :transactions_synced_through
      # Earliest day a statement request has actually served. While it sits later than
      # the connection's start date the history is still incomplete, so the next sync
      # asks for the whole range again instead of resuming at the end — which is how a
      # backfill survives the 90-day refusal until the user unlocks their full history.
      t.date :history_synced_from

      t.timestamps
    end

    add_index :fio_accounts,
              [ :fio_item_id, :fio_account_id ],
              unique: true,
              where: "fio_account_id IS NOT NULL",
              name: "index_fio_accounts_on_item_and_account_id"
  end
end
