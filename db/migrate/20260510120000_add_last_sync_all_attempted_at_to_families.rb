class AddLastSyncAllAttemptedAtToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :last_sync_all_attempted_at, :datetime
  end
end
