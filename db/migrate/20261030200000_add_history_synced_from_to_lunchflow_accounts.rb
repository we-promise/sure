class AddHistorySyncedFromToLunchflowAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :lunchflow_accounts, :history_synced_from, :datetime
  end
end
