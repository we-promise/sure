class AddUsageTypeToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :usage_type, :string
    add_check_constraint :accounts,
      "usage_type IS NULL OR usage_type IN ('personal', 'business')",
      name: "chk_accounts_usage_type"
  end
end
