class AddExcludedToAccounts < ActiveRecord::Migration[7.2]
  # Adds the excluded boolean column to accounts, defaulting to false
  def change
    add_column :accounts, :excluded, :boolean, default: false, null: false
  end
end
