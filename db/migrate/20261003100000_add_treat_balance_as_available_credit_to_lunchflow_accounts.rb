class AddTreatBalanceAsAvailableCreditToLunchflowAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :lunchflow_accounts, :treat_balance_as_available_credit, :boolean, default: false, null: false
  end
end
