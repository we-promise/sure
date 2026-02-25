class AddExcludedToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :excluded, :boolean, default: false, null: false
  end
end
