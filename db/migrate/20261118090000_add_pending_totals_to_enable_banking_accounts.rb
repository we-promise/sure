class AddPendingTotalsToEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_accounts, :pending_total, :decimal, precision: 19, scale: 4
    add_column :enable_banking_accounts, :anchor_pending_total, :decimal, precision: 19, scale: 4
  end
end
