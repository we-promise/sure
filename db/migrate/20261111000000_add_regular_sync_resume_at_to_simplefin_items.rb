class AddRegularSyncResumeAtToSimplefinItems < ActiveRecord::Migration[8.1]
  def change
    add_column :simplefin_items, :regular_sync_resume_at, :datetime
  end
end
