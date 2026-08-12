class AddDismissedAtToRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :dismissed_at, :datetime
  end
end
