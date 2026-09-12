class AddSyncStartDateToEnableBankingAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :enable_banking_accounts, :sync_start_date, :date
  end
end
