class BindProviderExecutionLeases < ActiveRecord::Migration[8.1]
  def change
    add_column :syncs, :provider_execution_revision, :bigint, null: false, default: 0
    add_check_constraint :syncs, "provider_execution_revision >= 0 AND (provider_execution_revision = 0 OR syncable_type = 'ProviderConnection')",
      name: "chk_sync_provider_execution"
    add_column :provider_connections, :lease_sync_id, :uuid
    add_column :provider_connections, :lease_sync_type, :string, null: false, default: "ProviderConnection"
    add_index :provider_connections, :lease_sync_id
    add_foreign_key :provider_connections, :syncs,
      column: [ :lease_sync_id, :id, :lease_sync_type ], primary_key: [ :id, :syncable_id, :syncable_type ], name: "fk_pc_lease_sync_owner"
    add_check_constraint :provider_connections,
      "lease_sync_type = 'ProviderConnection' AND (lease_sync_id IS NULL OR (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL))",
      name: "chk_pc_lease_sync"
  end
end
