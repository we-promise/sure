class AddExcludeFromReportsToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_index :accounts, [:family_id, :exclude_from_reports]
  end
end
