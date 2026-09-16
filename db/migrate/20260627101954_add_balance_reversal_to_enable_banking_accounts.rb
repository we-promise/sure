class AddBalanceReversalToEnableBankingAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :enable_banking_accounts, :treat_balance_as_available_credit, :boolean, default: false, null: false unless column_exists?(:enable_banking_accounts, :treat_balance_as_available_credit)
  end
end
