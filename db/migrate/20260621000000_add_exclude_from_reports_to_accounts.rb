class AddExcludeFromReportsToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :exclude_from_reports, :boolean, default: false, null: false
    add_index :accounts, [ :family_id, :exclude_from_reports ]
  end
end
