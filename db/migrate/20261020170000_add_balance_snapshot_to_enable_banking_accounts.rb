class AddBalanceSnapshotToEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_accounts, :balance_snapshot, :jsonb
  end
end
