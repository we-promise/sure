class AddProviderBalanceAdjustmentToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :provider_balance_adjustment, :decimal, precision: 19, scale: 4, default: 0, null: false
    add_column :accounts, :provider_balance_adjustment_reason, :string
  end
end
