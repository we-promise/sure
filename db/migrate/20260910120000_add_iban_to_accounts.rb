class AddIbanToAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts, :iban, :string unless column_exists?(:accounts, :iban)
  end

  def down
    remove_column :accounts, :iban, if_exists: true
  end
end
