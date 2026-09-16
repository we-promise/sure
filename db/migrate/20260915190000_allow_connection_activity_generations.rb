class AllowConnectionActivityGenerations < ActiveRecord::Migration[8.1]
  def up
    add_index :provider_sync_generations, [ :id, :stream ], unique: true, name: "idx_psg_resource"
    add_column :ingestion_batches, :generation_resource, :string
    execute "UPDATE ingestion_batches SET generation_resource = 'transactions' WHERE provider_sync_generation_id IS NOT NULL"
    add_foreign_key :ingestion_batches, :provider_sync_generations,
      column: [ :provider_sync_generation_id, :generation_resource ], primary_key: [ :id, :stream ], name: "fk_ib_generation_resource"
    add_foreign_key :provider_sync_checkpoints, :provider_sync_generations,
      column: [ :provider_sync_generation_id, :stream ], primary_key: [ :id, :stream ], name: "fk_psc_generation_resource"
    replace_constraints(activities: true)
  end

  def down
    if select_value("SELECT 1 FROM provider_sync_generations WHERE stream = 'activities' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Retained activity generations require an explicit archival disposition before rollback"
    end
    replace_constraints(activities: false)
    remove_foreign_key :provider_sync_checkpoints, name: "fk_psc_generation_resource"
    remove_foreign_key :ingestion_batches, name: "fk_ib_generation_resource"
    remove_column :ingestion_batches, :generation_resource
    remove_index :provider_sync_generations, name: "idx_psg_resource"
  end

  private
    def replace_constraints(activities:)
      remove_check_constraint :provider_sync_generations, name: "chk_psg_scope"
      remove_check_constraint :ingestion_batches, name: "chk_ib_generation_role"
      remove_check_constraint :provider_sync_checkpoints, name: "chk_psc_generation_scope"
      resources = activities ? "('transactions', 'activities')" : "('transactions')"
      add_check_constraint :provider_sync_generations,
        "provider_sync_type = 'ProviderConnection' AND stream IN #{resources} AND scope_key = 'connection'", name: "chk_psg_scope"
      resource_guard = activities ? "AND generation_resource IS NOT NULL AND generation_resource IN #{resources}" : ""
      absent_guard = activities ? "AND generation_resource IS NULL" : ""
      pages = activities ? "((stream = 'transaction_groups' AND generation_resource = 'transactions') OR (stream = 'activity_groups' AND generation_resource = 'activities'))" : "stream = 'transaction_groups'"
      children = activities ? "stream = generation_resource" : "stream = 'transactions'"
      add_check_constraint :ingestion_batches, <<~SQL.squish, name: "chk_ib_generation_role"
        (provider_sync_generation_id IS NULL AND generation_role IS NULL #{absent_guard}) OR
        (provider_sync_generation_id IS NOT NULL AND generation_role IS NOT NULL #{resource_guard} AND origin_kind = 'provider' AND provider_authorization_id IS NULL AND
          ((generation_role = 'page' AND #{pages} AND scope_key = 'connection' AND external_account_id IS NULL) OR
           (generation_role = 'account' AND #{children} AND external_account_id IS NOT NULL)))
      SQL
      add_check_constraint :provider_sync_checkpoints, <<~SQL.squish, name: "chk_psc_generation_scope"
        provider_sync_generation_id IS NULL OR
        (ingestion_batch_id IS NULL AND stream IN #{resources} AND scope_key = 'connection' AND external_account_id IS NULL AND provider_authorization_id IS NULL)
      SQL
    end
end
