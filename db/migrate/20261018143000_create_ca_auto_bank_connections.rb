class CreateCaAutoBankConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :ca_auto_bank_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.text :authentication_token
      t.text :account_identity
      t.text :pending_login_state
      t.string :request_session_id
      t.integer :connection_generation, null: false, default: 0
      t.string :status, null: false, default: "requires_update"
      t.datetime :session_expires_at
      t.datetime :snapshot_at
      t.string :last_sync_error_code
      t.timestamps
    end
    add_index :ca_auto_bank_items, [ :family_id, :owner_id ], unique: true
    add_check_constraint :ca_auto_bank_items,
      "status IN ('pending', 'connected', 'requires_update')", name: "chk_ca_auto_bank_items_status"

    create_table :ca_auto_bank_accounts, id: :uuid do |t|
      t.references :ca_auto_bank_item, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :uid, null: false
      t.string :report_uid, null: false
      t.string :kind, null: false
      t.string :name, null: false
      t.decimal :current_balance, precision: 19, scale: 4, null: false
      t.decimal :interest_rate, precision: 10, scale: 6
      t.date :effective_date
      t.date :maturity_date
      t.jsonb :deposit_metadata
      t.timestamps
    end
    add_index :ca_auto_bank_accounts, [ :ca_auto_bank_item_id, :uid ], unique: true
    add_check_constraint :ca_auto_bank_accounts,
      "kind IN ('libero', 'time_deposit')", name: "chk_ca_auto_bank_accounts_kind"
    add_check_constraint :ca_auto_bank_accounts, "current_balance >= 0", name: "chk_ca_auto_bank_accounts_balance"
  end
end
