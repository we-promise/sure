class AddWaitForSyncToSyncs < ActiveRecord::Migration[8.1]
  def change
    add_reference :syncs,
      :wait_for_sync,
      type: :uuid,
      foreign_key: { to_table: :syncs, on_delete: :nullify }
  end
end
