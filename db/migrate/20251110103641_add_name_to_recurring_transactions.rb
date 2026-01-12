class AddNameToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :recurring_transactions, :name, :string, if_not_exists: true
  end
end
