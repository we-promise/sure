class AddHiddenToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :hidden, :boolean, default: false, null: false
  end
end
