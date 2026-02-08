class RemoveParentTransactionIdFromTransactions < ActiveRecord::Migration[7.2]
  def change
    if foreign_key_exists?(:transactions, column: :parent_transaction_id)
      remove_foreign_key :transactions, column: :parent_transaction_id
    end

    if column_exists?(:transactions, :parent_transaction_id)
      remove_column :transactions, :parent_transaction_id, :uuid
    end
  end
end
