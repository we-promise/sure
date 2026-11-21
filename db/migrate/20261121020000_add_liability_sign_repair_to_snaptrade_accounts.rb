class AddLiabilitySignRepairToSnaptradeAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :snaptrade_accounts, :liability_signs_fixed_at, :datetime
    add_column :snaptrade_accounts, :activities_fetch_failed, :boolean, default: false, null: false
  end
end
