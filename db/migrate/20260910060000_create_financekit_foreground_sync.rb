class CreateFinancekitForegroundSync < ActiveRecord::Migration[8.1]
  def change
    create_table :financekit_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.uuid :enrollment_id, null: false
      t.string :enrollment_digest, null: false
      t.jsonb :consent, null: false
      t.string :status, null: false, default: "active"
      t.datetime :last_device_contact_at
      t.datetime :last_captured_at
      t.datetime :last_imported_at
      t.timestamps
    end
    add_index :financekit_items, [ :family_id, :enrollment_id ], unique: true

    create_table :financekit_accounts, id: :uuid do |t|
      t.references :financekit_item, type: :uuid, null: false, foreign_key: true
      t.uuid :source_id, null: false
      t.integer :mapping_version, null: false, default: 1
      t.string :mapping_digest, null: false
      t.string :name, null: false
      t.string :currency, null: false
      t.string :accountable_type, null: false
      t.string :subtype, null: false
      t.string :ledger_timezone, null: false
      t.jsonb :booked_balance
      t.jsonb :available_balance
      t.datetime :observed_at
      t.timestamps
    end
    add_index :financekit_accounts, [ :financekit_item_id, :source_id ], unique: true

    create_table :financekit_batches, id: :uuid do |t|
      t.references :financekit_item, type: :uuid, null: false, foreign_key: true
      t.uuid :batch_id, null: false
      t.string :status, null: false, default: "applied"
      t.string :error_code
      t.jsonb :counts, null: false, default: {}
      t.datetime :captured_at, null: false
      t.datetime :applied_at
      t.references :sync, type: :uuid, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :financekit_batches, [ :financekit_item_id, :batch_id ], unique: true, name: "financekit_batch_identity"

    create_table :financekit_transactions, id: :uuid do |t|
      t.references :financekit_account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :source_id, null: false
      t.string :status, null: false
      t.jsonb :raw_payload
      t.boolean :ledger_imported, null: false, default: false
      t.datetime :tombstoned_at
      t.boolean :review_required, null: false, default: false
      t.timestamps
    end
    add_index :financekit_transactions, [ :financekit_account_id, :source_id ], unique: true, name: "financekit_transaction_identity"
  end
end
