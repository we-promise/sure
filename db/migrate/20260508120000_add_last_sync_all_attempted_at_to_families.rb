class AddLastSyncAllAttemptedAtToFamilies < ActiveRecord::Migration[8.0]
  def change
    add_column :families, :last_sync_all_attempted_at, :datetime
  end
end
