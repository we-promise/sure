class AddAutoPostToRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :recurring_transactions, :auto_post, :boolean, null: false, default: false
    add_index :recurring_transactions, [ :auto_post, :next_expected_date ],
              where: "status = 'active' AND auto_post = true",
              name: "index_recurring_txns_due_for_auto_post"
  end
end
