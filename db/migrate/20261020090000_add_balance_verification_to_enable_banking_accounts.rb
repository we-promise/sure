class AddBalanceVerificationToEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_accounts, :balance_evidence_verified, :boolean, default: false, null: false
    add_column :enable_banking_accounts, :balance_verified, :boolean, default: false, null: false
  end
end
