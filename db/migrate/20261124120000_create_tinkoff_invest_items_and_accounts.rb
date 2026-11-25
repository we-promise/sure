# frozen_string_literal: true

class CreateTinkoffInvestItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :tinkoff_invest_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.string :environment, default: "live", null: false
      t.string :base_url
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.datetime :sync_start_date
      t.text :api_key
      t.jsonb :raw_accounts_payload, default: [], null: false

      t.timestamps
    end

    add_index :tinkoff_invest_items, :status

    create_table :tinkoff_invest_accounts, id: :uuid do |t|
      t.references :tinkoff_invest_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :tinkoff_invest_account_id
      t.string :account_type
      t.string :account_status
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.string :operations_cursor
      t.datetime :last_synced_at
      t.jsonb :raw_payload
      t.jsonb :raw_portfolio_payload, default: {}, null: false
      t.jsonb :raw_operations_payload, default: [], null: false

      t.timestamps
    end

    add_index :tinkoff_invest_accounts, [ :tinkoff_invest_item_id, :tinkoff_invest_account_id ],
      unique: true,
      where: "(tinkoff_invest_account_id IS NOT NULL)",
      name: "index_tinkoff_invest_accounts_on_item_and_account_id"
  end
end
