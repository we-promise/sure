class AddEffectiveSyncStartDateToEnableBankingItems < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_items, :effective_sync_start_date, :date
  end
end
