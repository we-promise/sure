# frozen_string_literal: true

class CreateSharesightItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :sharesight_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.string :client_id
      t.string :client_secret

      t.timestamps
    end

    add_index :sharesight_items, :status

    # One row per Sharesight portfolio. sharesight_account_id is the portfolio's id.
    create_table :sharesight_accounts, id: :uuid do |t|
      t.references :sharesight_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :sharesight_account_id
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.jsonb :raw_payload
      t.jsonb :raw_holdings_payload, default: [], null: false
      t.jsonb :raw_trades_payload, default: [], null: false
      t.jsonb :raw_payouts_payload, default: [], null: false
      t.jsonb :raw_cash_transactions_payload, default: [], null: false

      t.timestamps
    end

    add_index :sharesight_accounts, [ :sharesight_item_id, :sharesight_account_id ],
      unique: true,
      where: "(sharesight_account_id IS NOT NULL)",
      name: "index_sharesight_accounts_on_item_and_account_id"
  end
end
