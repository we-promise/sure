class AddProviderBalanceAdjustmentToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :provider_balance_adjustment, :decimal, precision: 19, scale: 4, default: 0, null: false
    add_column :accounts, :provider_balance_adjustment_reason, :string
    add_column :accounts, :provider_balance_adjustment_effective_date, :date
    add_column :accounts, :provider_balance_adjustment_provider_balance, :decimal, precision: 19, scale: 4
    add_column :accounts, :provider_balance_adjustment_caught_up_amount, :decimal, precision: 19, scale: 4
    add_column :accounts, :provider_balance_adjustment_caught_up_at, :datetime
  end
end
