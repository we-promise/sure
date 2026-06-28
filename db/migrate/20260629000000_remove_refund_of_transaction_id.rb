class RemoveRefundOfTransactionId < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :transactions, column: :refund_of_transaction_id
    remove_index :transactions, :refund_of_transaction_id
    remove_column :transactions, :refund_of_transaction_id, :uuid
  end
end
