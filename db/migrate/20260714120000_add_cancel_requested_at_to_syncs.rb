class AddCancelRequestedAtToSyncs < ActiveRecord::Migration[7.2]
  def change
    add_column :syncs, :cancel_requested_at, :datetime
  end
end
