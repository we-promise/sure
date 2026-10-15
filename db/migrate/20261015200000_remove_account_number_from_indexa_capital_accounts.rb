# Indexa Capital stored the same value in account_number and
# indexa_capital_account_id. Every lookup already uses
# indexa_capital_account_id, and account_number was only read by the setup
# view, where it was shown unmasked.
class RemoveAccountNumberFromIndexaCapitalAccounts < ActiveRecord::Migration[8.1]
  def up
    remove_column :indexa_capital_accounts, :account_number
  end

  def down
    add_column :indexa_capital_accounts, :account_number, :string
    execute <<~SQL
      UPDATE indexa_capital_accounts SET account_number = indexa_capital_account_id
    SQL
  end
end
