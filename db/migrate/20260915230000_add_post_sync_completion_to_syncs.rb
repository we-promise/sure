class AddPostSyncCompletionToSyncs < ActiveRecord::Migration[8.1]
  def change
    # Do not infer completion for historical terminal rows: a failed parent may
    # still be waiting for children before its first post-sync pass.
    add_column :syncs, :post_sync_completed_at, :datetime
  end
end
