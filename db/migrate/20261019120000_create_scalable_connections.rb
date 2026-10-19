class CreateScalableConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :scalable_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.text :credentials
      t.text :person_identity
      t.text :pending_login_state
      t.integer :connection_generation, null: false, default: 0
      t.string :status, null: false, default: "requires_update"
      t.datetime :snapshot_at
      t.datetime :next_sync_at
      t.string :last_sync_error_code
      t.timestamps
    end
    add_index :scalable_items, [ :family_id, :owner_id ], unique: true
    add_check_constraint :scalable_items,
      "status IN ('pending', 'connected', 'requires_update')", name: "chk_scalable_items_status"

    create_table :scalable_accounts, id: :uuid do |t|
      t.references :scalable_item, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :uid, null: false
      t.string :name, null: false
      t.string :currency, null: false
      t.string :kind, null: false
      t.decimal :current_balance, precision: 19, scale: 4, null: false
      t.decimal :cash_balance, precision: 19, scale: 4, null: false
      t.text :raw_metadata
      t.datetime :snapshot_at
      t.timestamps
    end
    add_index :scalable_accounts, [ :scalable_item_id, :uid ], unique: true
    add_check_constraint :scalable_accounts, "kind IN ('broker', 'overnight')", name: "chk_scalable_accounts_kind"
  end
end
