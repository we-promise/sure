class AddExcludeFromReportsToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :exclude_from_reports, :boolean, default: false, null: false
  end
end
