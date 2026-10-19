class AddDirectaAndCaAutoBankSyncPacing < ActiveRecord::Migration[8.1]
  def change
    add_column :directa_items, :last_sync_attempt_at, :datetime
    add_column :directa_items, :last_history_sync_attempt_at, :datetime
    add_column :directa_items, :next_sync_at, :datetime

    add_column :ca_auto_bank_items, :last_sync_attempt_at, :datetime
    add_column :ca_auto_bank_items, :next_sync_at, :datetime
  end
end
