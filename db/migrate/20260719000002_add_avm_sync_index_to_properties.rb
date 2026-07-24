class AddAvmSyncIndexToProperties < ActiveRecord::Migration[7.2]
  def change
    # Keyed on avm_last_synced_on (matching the daily job's
    # ORDER BY avm_last_synced_on ASC NULLS FIRST) so the index also
    # serves the sort, not just the avm_provider IS NOT NULL filter.
    add_index :properties, :avm_last_synced_on,
      order: { avm_last_synced_on: "ASC NULLS FIRST" },
      where: "avm_provider IS NOT NULL",
      name: "index_properties_on_avm_provider_sync"
  end
end
