class AddActivitiesFetchPendingToSnaptradeAccounts < ActiveRecord::Migration[7.2]
  def change
    unless column_exists?(:snaptrade_accounts, :activities_fetch_pending)
      add_column :snaptrade_accounts, :activities_fetch_pending, :boolean, default: false
    end
  end
end
