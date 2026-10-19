class CreateFinancekitDevicePublisher < ActiveRecord::Migration[8.1]
  def change
    create_table :financekit_items, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :replaces_financekit_item, type: :uuid, foreign_key: { to_table: :financekit_items, on_delete: :nullify }
      t.uuid :enrollment_id, null: false
      t.uuid :publisher_id, null: false
      t.uuid :stream_id
      t.bigint :generation, null: false, default: 1
      t.bigint :next_sequence, null: false, default: 1
      t.string :predecessor_digest
      t.string :credential_digest
      t.string :enrollment_digest, null: false
      t.jsonb :consent, null: false
      t.string :status, null: false, default: "pending_mapping"
      t.string :repair_reason
      t.datetime :last_device_contact_at
      t.datetime :last_accepted_at
      t.datetime :last_captured_at
      t.datetime :last_imported_at
      t.datetime :last_downstream_at
      t.timestamps
    end
    add_index :financekit_items, [ :family_id, :enrollment_id ], unique: true
    add_index :financekit_items, :publisher_id, unique: true
    add_check_constraint :financekit_items, "generation > 0 AND next_sequence > 0", name: "financekit_items_positive_stream"

    create_table :financekit_account_lineages, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :financekit_account_lineages, [ :family_id, :account_id ], unique: true,
      where: "account_id IS NOT NULL", name: "financekit_lineage_canonical_account"

    create_table :financekit_accounts, id: :uuid do |t|
      t.references :financekit_item, type: :uuid, null: false, foreign_key: true
      t.references :financekit_account_lineage, type: :uuid, null: false, foreign_key: true, index: { name: "index_financekit_accounts_on_lineage_id" }
      t.uuid :source_id, null: false
      t.integer :mapping_version, null: false, default: 1
      t.string :mapping_digest, null: false
      t.string :name, null: false
      t.string :institution_name
      t.string :currency, null: false
      t.string :accountable_type, null: false
      t.string :subtype, null: false
      t.string :ledger_timezone, null: false
      t.datetime :unavailable_at
      t.timestamps
    end
    add_index :financekit_accounts, [ :financekit_item_id, :source_id ], unique: true
    add_index :financekit_accounts, [ :financekit_item_id, :financekit_account_lineage_id ], unique: true,
      name: "financekit_item_lineage_identity"

    create_table :financekit_batches, id: :uuid do |t|
      t.references :financekit_item, type: :uuid, null: false, foreign_key: true
      t.references :sync, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :batch_id, null: false
      t.uuid :stream_id, null: false
      t.uuid :capture_id, null: false
      t.bigint :generation, null: false
      t.bigint :sequence, null: false
      t.string :predecessor_digest
      t.string :payload_digest, null: false
      t.integer :chunk_index, null: false
      t.integer :chunk_count, null: false
      t.string :capture_mode, null: false
      t.boolean :snapshot_complete, null: false, default: false
      t.binary :payload
      t.string :status, null: false, default: "accepted"
      t.string :error_code
      t.jsonb :counts, null: false, default: {}
      t.integer :attempts, null: false, default: 0
      t.datetime :retry_at
      t.datetime :captured_at, null: false
      t.datetime :accepted_at, null: false
      t.datetime :applied_at
      t.datetime :downstream_completed_at
      t.timestamps
    end
    add_index :financekit_batches, [ :financekit_item_id, :generation, :batch_id ], unique: true,
      name: "financekit_batch_identity"
    add_index :financekit_batches, [ :financekit_item_id, :generation, :stream_id, :sequence ], unique: true,
      name: "financekit_stream_sequence"
    add_index :financekit_batches, [ :status, :retry_at ]
    add_check_constraint :financekit_batches,
      "sequence > 0 AND generation > 0 AND chunk_index >= 0 AND chunk_count > 0 AND chunk_index < chunk_count",
      name: "financekit_batch_stream_values"

    create_table :financekit_balance_observations, id: :uuid do |t|
      t.references :financekit_account_lineage, type: :uuid, null: false, foreign_key: true,
        index: { name: "index_financekit_balances_on_lineage_id" }
      t.references :financekit_account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :source_id, null: false
      t.string :kind, null: false
      t.datetime :observed_at, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :direction, null: false
      t.timestamps
    end
    add_index :financekit_balance_observations,
      [ :financekit_account_lineage_id, :source_id, :kind, :observed_at ], unique: true,
      name: "financekit_balance_observation_identity"

    create_table :financekit_transactions, id: :uuid do |t|
      t.references :financekit_account_lineage, type: :uuid, null: false, foreign_key: true,
        index: { name: "index_financekit_transactions_on_lineage_id" }
      t.references :financekit_account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :source_id, null: false
      t.bigint :generation, null: false
      t.bigint :sequence, null: false
      t.string :status, null: false
      t.jsonb :raw_payload
      t.boolean :ledger_imported, null: false, default: false
      t.datetime :tombstoned_at
      t.boolean :review_required, null: false, default: false
      t.timestamps
    end
    add_index :financekit_transactions, [ :financekit_account_lineage_id, :source_id ], unique: true,
      name: "financekit_transaction_lineage_identity"

    create_table :financekit_conflicts, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :financekit_item, type: :uuid, null: false, foreign_key: true
      t.references :financekit_account_lineage, type: :uuid, foreign_key: { on_delete: :nullify },
        index: { name: "index_financekit_conflicts_on_lineage_id" }
      t.references :financekit_transaction, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :resolved_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :kind, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :details, null: false, default: {}
      t.string :resolution
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :financekit_conflicts, [ :financekit_item_id, :status, :created_at ],
      name: "financekit_conflicts_status_created"
  end
end
