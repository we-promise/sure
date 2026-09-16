class CreateTrading212ItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :trading212_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.string :environment, default: "live", null: false
      t.string :currency
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.string :api_key
      t.jsonb :raw_instruments_payload, default: [], null: false

      t.timestamps
    end

    add_index :trading212_items, :status

    create_table :trading212_accounts, id: :uuid do |t|
      t.references :trading212_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :trading212_account_id
      t.string :account_type
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.jsonb :raw_positions_payload, default: [], null: false
      t.jsonb :raw_orders_payload, default: [], null: false
      t.jsonb :raw_dividends_payload, default: [], null: false
      t.jsonb :raw_transactions_payload, default: [], null: false
      t.datetime :last_positions_sync
      t.datetime :last_orders_sync

      t.timestamps
    end

    add_index :trading212_accounts, [ :trading212_item_id, :trading212_account_id ],
      unique: true,
      where: "(trading212_account_id IS NOT NULL)",
      name: "index_trading212_accounts_on_item_and_account_id"
  end
end
