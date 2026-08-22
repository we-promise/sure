class AddIndexOnDismissedAtToRecurringTransactions < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :recurring_transactions, [ :family_id, :dismissed_at ],
      name: "index_recurring_transactions_on_family_id_and_dismissed_at",
      algorithm: :concurrently
  end
end
