class AddSyncStartDateToSnaptradeAccounts < ActiveRecord::Migration[7.2]
  def change
    unless column_exists?(:snaptrade_accounts, :sync_start_date)
      add_column :snaptrade_accounts, :sync_start_date, :date
    end
  end
end
