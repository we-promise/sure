class AddIngestionReferenceKeys < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :imports, [ :id, :family_id ], unique: true,
      name: "idx_imports_ingestion_tenant", algorithm: :concurrently
    add_index :account_statements, [ :id, :family_id ], unique: true,
      name: "idx_statements_ingestion_tenant", algorithm: :concurrently
    add_index :syncs, [ :id, :syncable_id, :syncable_type ], unique: true,
      name: "idx_syncs_ingestion_owner", algorithm: :concurrently
  end
end
