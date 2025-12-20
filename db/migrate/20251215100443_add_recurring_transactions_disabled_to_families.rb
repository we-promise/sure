class AddRecurringTransactionsDisabledToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :recurring_transactions_disabled, :boolean, default: false, null: false
  end
end
