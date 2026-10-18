class CreateDirectaItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :directa_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.text :broker_account
      t.text :account_identity
      t.text :multi_token
      t.text :mono_token
      t.text :pending_login_state
      t.integer :connection_generation, null: false, default: 0
      t.string :status, null: false, default: "requires_update"
      t.datetime :portfolio_snapshot_at
      t.string :last_sync_error_code

      t.timestamps
    end

    add_index :directa_items, [ :family_id, :owner_id ], unique: true
    add_check_constraint :directa_items,
                         "status IN ('pending', 'connected', 'requires_update')",
                         name: "chk_directa_items_status"

    create_table :directa_accounts, id: :uuid do |t|
      t.references :directa_item, type: :uuid, null: false, index: { unique: true },
                                  foreign_key: { on_delete: :cascade }
      t.string :currency, limit: 3
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4
      t.jsonb :raw_position_metadata

      t.timestamps
    end
  end
end
