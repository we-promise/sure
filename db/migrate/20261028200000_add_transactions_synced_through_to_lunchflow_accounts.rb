class AddTransactionsSyncedThroughToLunchflowAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :lunchflow_accounts, :transactions_synced_through, :datetime
  end
end
