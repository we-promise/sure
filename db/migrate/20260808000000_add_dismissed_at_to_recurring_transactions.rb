class AddDismissedAtToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :recurring_transactions, :dismissed_at, :datetime
  end
end
