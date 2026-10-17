class AddLastAttemptedAtToSyncs < ActiveRecord::Migration[8.1]
  def change
    add_column :syncs, :last_attempted_at, :datetime
  end
end
