class CreateEtoroItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :etoro_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.boolean :own_securities, default: false, null: false
      t.string :api_key
      t.string :user_key
      t.jsonb :raw_instruments_payload, default: {}, null: false

      t.timestamps
    end

    add_index :etoro_items, :status

    create_table :etoro_accounts, id: :uuid do |t|
      t.references :etoro_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :etoro_account_id
      t.string :account_type
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.jsonb :raw_positions_payload, default: [], null: false
      t.jsonb :raw_trades_payload, default: [], null: false
      t.jsonb :raw_balance_history_payload, default: [], null: false
      t.jsonb :position_settlement_types, default: {}, null: false
      t.date :trades_synced_through
      t.datetime :last_positions_sync

      t.timestamps
    end

    add_index :etoro_accounts, [ :etoro_item_id, :etoro_account_id ],
      unique: true,
      where: "(etoro_account_id IS NOT NULL)",
      name: "index_etoro_accounts_on_item_and_account_id"
  end
end
