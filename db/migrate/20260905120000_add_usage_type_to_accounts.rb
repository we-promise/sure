class AddUsageTypeToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :usage_type, :string, null: false, default: "personal"
  end
end
