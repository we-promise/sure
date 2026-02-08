class AddOriginalExpenseIdToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :original_expense_id, :uuid unless column_exists?(:transactions, :original_expense_id)
    add_index :transactions, :original_expense_id unless index_exists?(:transactions, :original_expense_id)
  end
end
