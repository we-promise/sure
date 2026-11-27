class AddFullResyncRequestedToSyncs < ActiveRecord::Migration[8.1]
  # A running sync cannot widen its window. A loan input change during that
  # sync marks it here so a full sync runs after the current one finishes.
  def change
    add_column :syncs, :full_resync_requested, :boolean, default: false, null: false
  end
end
