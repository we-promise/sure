class AddEarlyFetchColumnsToEnableBanking < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_items, :full_history_fetch_requested_at, :datetime
    add_column :enable_banking_accounts, :early_fetched_at, :datetime
  end
end
