class AddManualAndAmountVarianceToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :recurring_transactions, :manual, :boolean, default: false, null: false
    add_column :recurring_transactions, :expected_amount_min, :decimal, precision: 19, scale: 4
    add_column :recurring_transactions, :expected_amount_max, :decimal, precision: 19, scale: 4
    add_column :recurring_transactions, :expected_amount_avg, :decimal, precision: 19, scale: 4
  end
end
