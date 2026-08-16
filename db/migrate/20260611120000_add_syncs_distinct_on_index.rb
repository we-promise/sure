class AddSyncsDistinctOnIndex < ActiveRecord::Migration[7.2]
  def change
    add_index :syncs,
              [ :syncable_type, :syncable_id, :created_at, :id ],
              order: { created_at: :desc, id: :desc },
              name: "index_syncs_on_syncable_and_created_at_and_id"
  end
end
