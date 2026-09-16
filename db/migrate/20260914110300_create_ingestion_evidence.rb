class CreateIngestionEvidence < ActiveRecord::Migration[8.1]
  def change
    create_table :account_source_policies, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.uuid :family_id, null: false
      t.uuid :account_provider_id, null: false
      t.string :resource, null: false
      t.integer :revision, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index [ :account_id, :resource ], unique: true, where: "active", name: "idx_source_policies_active"
      t.index [ :account_id, :resource, :revision ], unique: true, name: "idx_source_policies_revision"
      t.check_constraint "revision > 0", name: "source_policies_positive_revision"
      t.check_constraint "resource IN ('transactions','balances','holdings','activities','historical_balances')",
        name: "source_policies_resource"
    end
    add_foreign_key :account_source_policies, :account_providers,
      column: [ :account_provider_id, :account_id, :family_id ], primary_key: [ :id, :account_id, :family_id ]

    add_index :ingestion_batches, [ :id, :external_account_id, :family_id ], unique: true, name: "idx_ib_external_account_origin"
    add_index :ingestion_batches, [ :id, :account_statement_id, :family_id ], unique: true, name: "idx_ib_statement_origin"

    create_table :source_records, id: :uuid do |t|
      t.uuid :family_id, null: false
      # Provider observations may precede account setup. Entry/HoldingSource FKs
      # still require an exact non-null financial-account binding to publish.
      t.uuid :account_id
      t.uuid :external_account_id
      t.uuid :account_statement_id
      t.uuid :ingestion_batch_id, null: false
      t.string :kind, null: false
      t.string :external_id, null: false
      t.string :input_external_id, null: false
      t.integer :input_occurrence, null: false, default: 0
      t.jsonb :observation_order, null: false, default: []
      t.boolean :pending, null: false, default: false
      t.boolean :withdrawn, null: false, default: false
      t.timestamps
      t.index [ :external_account_id, :kind, :external_id ], unique: true, name: "idx_source_records_provider_identity"
      t.index [ :account_statement_id, :kind, :external_id ], unique: true, name: "idx_source_records_document_identity"
      t.index [ :id, :account_id, :family_id ], unique: true, name: "idx_source_records_identity_tenant"
      t.index [ :external_account_id, :kind, :input_external_id, :input_occurrence ], name: "idx_source_records_input_identity"
      t.check_constraint "input_occurrence >= 0", name: "source_records_occurrence"
      t.check_constraint "jsonb_typeof(observation_order) = 'array'", name: "source_records_observation_order"
      t.check_constraint "num_nonnulls(external_account_id, account_statement_id) = 1", name: "source_records_one_origin"
      t.check_constraint "account_statement_id IS NULL OR account_id IS NOT NULL", name: "source_records_statement_account"
      t.check_constraint "kind IN ('transaction','activity','holding')", name: "source_records_kind"
    end
    add_foreign_key :source_records, :accounts, column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ]
    add_foreign_key :source_records, :external_accounts, column: [ :external_account_id, :family_id ], primary_key: [ :id, :family_id ]
    add_foreign_key :source_records, :account_statements, column: [ :account_statement_id, :family_id ], primary_key: [ :id, :family_id ]
    add_foreign_key :source_records, :ingestion_batches, column: [ :ingestion_batch_id, :family_id ], primary_key: [ :id, :family_id ]
    add_foreign_key :source_records, :ingestion_batches,
      column: [ :ingestion_batch_id, :external_account_id, :family_id ], primary_key: [ :id, :external_account_id, :family_id ], name: "fk_source_records_provider_batch"
    add_foreign_key :source_records, :ingestion_batches,
      column: [ :ingestion_batch_id, :account_statement_id, :family_id ], primary_key: [ :id, :account_statement_id, :family_id ], name: "fk_source_records_statement_batch"

    create_table :entry_sources, id: :uuid do |t|
      t.uuid :source_record_id, null: false
      t.uuid :entry_id
      t.uuid :entry_identity, null: false
      t.uuid :family_id, null: false
      t.uuid :account_id, null: false
      t.string :role, null: false
      t.string :match_method, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index :source_record_id, unique: true, where: "active", name: "idx_entry_sources_current"
      t.index :entry_id
      t.check_constraint "role IN ('posting','evidence')", name: "entry_sources_role"
      t.check_constraint "NOT active OR entry_id IS NOT NULL", name: "entry_sources_active_entry"
    end
    add_foreign_key :entry_sources, :source_records,
      column: [ :source_record_id, :account_id, :family_id ], primary_key: [ :id, :account_id, :family_id ]
    add_foreign_key :entry_sources, :entries, column: [ :entry_id, :account_id ], primary_key: [ :id, :account_id ]

    create_table :holding_sources, id: :uuid do |t|
      t.uuid :source_record_id, null: false
      t.uuid :holding_id
      t.uuid :holding_identity, null: false
      t.uuid :family_id, null: false
      t.uuid :account_id, null: false
      t.string :role, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index :source_record_id, unique: true, where: "active", name: "idx_holding_sources_current"
      t.index :holding_id
      t.check_constraint "role IN ('posting','evidence')", name: "holding_sources_role"
      t.check_constraint "NOT active OR holding_id IS NOT NULL", name: "holding_sources_active_holding"
    end
    add_foreign_key :holding_sources, :source_records,
      column: [ :source_record_id, :account_id, :family_id ], primary_key: [ :id, :account_id, :family_id ]
    add_foreign_key :holding_sources, :holdings, column: [ :holding_id, :account_id ], primary_key: [ :id, :account_id ]
  end
end
