class AddAvmSyncIndexToProperties < ActiveRecord::Migration[7.2]
  def change
    add_index :properties, [ :avm_provider, :avm_last_synced_on ],
      where: "avm_provider IS NOT NULL",
      name: "index_properties_on_avm_provider_sync"
  end
end
