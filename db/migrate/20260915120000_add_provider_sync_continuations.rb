class AddProviderSyncContinuations < ActiveRecord::Migration[8.1]
  def change
    add_column :syncs, :resume_at, :datetime
    add_column :syncs, :provider_attempt, :integer, null: false, default: 0
    add_column :syncs, :provider_work_finished_at, :datetime
    add_reference :syncs, :predecessor, type: :uuid
    add_foreign_key :syncs, :syncs, column: [ :predecessor_id, :syncable_id, :syncable_type ],
      primary_key: [ :id, :syncable_id, :syncable_type ], name: "fk_sync_predecessor_owner"
    add_check_constraint :syncs, "predecessor_id IS NULL OR (predecessor_id <> id AND syncable_type = 'ProviderConnection')",
      name: "chk_sync_predecessor_origin"
    add_check_constraint :syncs, "provider_attempt >= 0", name: "chk_sync_provider_attempt"
    add_check_constraint :syncs, "resume_at IS NULL OR syncable_type = 'ProviderConnection'", name: "chk_sync_resume_origin"
    add_index :syncs, [ :syncable_type, :syncable_id ], where: "resume_at IS NOT NULL AND status IN ('pending', 'syncing')",
      name: "idx_sync_provider_continuation"
    add_index :syncs, :predecessor_id, unique: true,
      where: "predecessor_id IS NOT NULL AND status IN ('pending', 'syncing') AND cancel_requested_at IS NULL",
      name: "idx_sync_one_active_successor"
  end
end
