class AddIgnoredToIndexaCapitalAndEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :indexa_capital_accounts, :ignored, :boolean, default: false, null: false
    add_column :enable_banking_accounts, :ignored, :boolean, default: false, null: false
  end
end
