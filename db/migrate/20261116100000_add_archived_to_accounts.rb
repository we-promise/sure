class AddArchivedToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :archived, :boolean, default: false, null: false
  end
end
