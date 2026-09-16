class AddProviderSyncGenerations < ActiveRecord::Migration[8.1]
  def change
    add_column :external_accounts, :transaction_backfill_required, :boolean, null: false, default: false
    add_column :account_providers, :lock_version, :integer, null: false, default: 0
    add_column :provider_authorization_accounts, :lock_version, :integer, null: false, default: 0

    create_table :provider_sync_generations, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :provider_connection, type: :uuid, null: false, foreign_key: true
      t.references :sync, type: :uuid, null: false, foreign_key: true
      t.string :provider_sync_type, null: false, default: "ProviderConnection"
      t.string :stream, null: false, default: "transactions"
      t.string :scope_key, null: false, default: "connection"
      t.string :status, null: false, default: "fetching"
      t.text :start_cursor
      t.text :terminal_cursor
      t.text :context_snapshot
      t.bigint :writer_epoch, null: false
      t.integer :page_count, null: false, default: 0
      t.integer :child_count, null: false, default: 0
      t.datetime :sealed_at
      t.datetime :applied_at
      t.string :error_code
      t.timestamps
    end
    add_index :provider_sync_generations, [ :id, :provider_connection_id, :family_id ], unique: true, name: "idx_psg_owner"
    add_index :provider_sync_generations, [ :id, :provider_connection_id, :family_id, :sync_id, :writer_epoch ], unique: true, name: "idx_psg_capture_owner"
    add_index :provider_sync_generations, [ :provider_connection_id, :stream, :scope_key ], unique: true,
      where: "status IN ('fetching', 'sealed')", name: "idx_psg_unfinished"
    add_index :provider_sync_generations, [ :sync_id, :stream ], unique: true,
      where: "status = 'applied'", name: "idx_psg_sync_applied"
    add_foreign_key :provider_sync_generations, :provider_connections,
      column: [ :provider_connection_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_psg_connection_tenant"
    add_foreign_key :provider_sync_generations, :syncs,
      column: [ :sync_id, :provider_connection_id, :provider_sync_type ], primary_key: [ :id, :syncable_id, :syncable_type ], name: "fk_psg_sync_owner"
    add_check_constraint :provider_sync_generations, "provider_sync_type = 'ProviderConnection' AND stream = 'transactions' AND scope_key = 'connection'", name: "chk_psg_scope"
    add_check_constraint :provider_sync_generations, "status IN ('fetching', 'sealed', 'applied', 'abandoned')", name: "chk_psg_status"
    add_check_constraint :provider_sync_generations, "writer_epoch >= 0 AND page_count >= 0 AND child_count >= 0", name: "chk_psg_counts"
    add_check_constraint :provider_sync_generations, "status NOT IN ('sealed', 'applied') OR (terminal_cursor IS NOT NULL AND sealed_at IS NOT NULL AND page_count > 0)", name: "chk_psg_sealed"
    add_check_constraint :provider_sync_generations, "(status = 'applied') = (applied_at IS NOT NULL)", name: "chk_psg_applied"

    add_reference :ingestion_batches, :provider_sync_generation, type: :uuid
    add_column :ingestion_batches, :generation_role, :string
    add_foreign_key :ingestion_batches, :provider_sync_generations,
      column: [ :provider_sync_generation_id, :provider_connection_id, :family_id, :sync_id, :writer_epoch ],
      primary_key: [ :id, :provider_connection_id, :family_id, :sync_id, :writer_epoch ], name: "fk_ib_generation_owner"
    add_index :ingestion_batches, [ :provider_sync_generation_id, :generation_role, :sequence ], unique: true,
      where: "provider_sync_generation_id IS NOT NULL", name: "idx_ib_generation_sequence"
    add_check_constraint :ingestion_batches, <<~SQL.squish, name: "chk_ib_generation_role"
      (provider_sync_generation_id IS NULL AND generation_role IS NULL) OR
      (provider_sync_generation_id IS NOT NULL AND generation_role IS NOT NULL AND origin_kind = 'provider' AND provider_authorization_id IS NULL AND
        ((generation_role = 'page' AND stream = 'transaction_groups' AND scope_key = 'connection' AND external_account_id IS NULL) OR
         (generation_role = 'account' AND stream = 'transactions' AND external_account_id IS NOT NULL)))
    SQL

    add_reference :provider_sync_checkpoints, :provider_sync_generation, type: :uuid
    add_foreign_key :provider_sync_checkpoints, :provider_sync_generations,
      column: [ :provider_sync_generation_id, :provider_connection_id, :family_id ], primary_key: [ :id, :provider_connection_id, :family_id ], name: "fk_psc_generation_owner"
    add_check_constraint :provider_sync_checkpoints, <<~SQL.squish, name: "chk_psc_generation_scope"
      provider_sync_generation_id IS NULL OR
      (ingestion_batch_id IS NULL AND stream = 'transactions' AND scope_key = 'connection' AND external_account_id IS NULL AND provider_authorization_id IS NULL)
    SQL
  end
end
