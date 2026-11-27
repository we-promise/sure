class AddDeclaredOnToRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :declared_on, :date
  end
end
