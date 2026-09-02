class CreateTradeRepublicItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :trade_republic_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.string :currency
      t.string :phone_number
      t.text :session_blob
      t.text :pending_login_state
      t.string :newest_event_id
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      t.timestamps
    end

    add_index :trade_republic_items, :status

    create_table :trade_republic_accounts, id: :uuid do |t|
      t.references :trade_republic_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :trade_republic_account_id
      t.string :account_type
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.jsonb :raw_positions_payload, default: [], null: false
      t.jsonb :raw_timeline_payload, default: [], null: false
      t.datetime :last_positions_sync
      t.boolean :holdings_snapshot_complete, default: false, null: false
      t.string :kind, default: "portfolio", null: false

      t.timestamps
    end

    add_index :trade_republic_accounts, [ :trade_republic_item_id, :trade_republic_account_id ],
      unique: true,
      where: "(trade_republic_account_id IS NOT NULL)",
      name: "index_trade_republic_accounts_on_item_and_account_id"

    add_index :trade_republic_accounts, [ :trade_republic_item_id, :kind ], unique: true
  end
end
