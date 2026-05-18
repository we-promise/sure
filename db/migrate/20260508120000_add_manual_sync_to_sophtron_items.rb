class AddManualSyncToSophtronItems < ActiveRecord::Migration[7.2]
  def change
    add_column :sophtron_items, :manual_sync, :boolean, null: false, default: false
    add_column :sophtron_items, :current_job_sophtron_account_id, :uuid
    add_index :sophtron_items, :current_job_sophtron_account_id
  end
end
