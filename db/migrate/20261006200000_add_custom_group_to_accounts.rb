class AddCustomGroupToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :custom_group, :string
  end
end
