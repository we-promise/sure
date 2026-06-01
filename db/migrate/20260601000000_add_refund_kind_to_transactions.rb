class AddRefundKindToTransactions < ActiveRecord::Migration[7.2]
  def change
    # Optional back-link from a refund to the transaction it offsets.
    # Nullable — a refund can exist without a linked original (e.g. manually created,
    # or the original was deleted).  No data migration needed: all existing rows keep
    # their current kind value ('standard' by default).
    add_column :transactions, :refund_of_transaction_id, :uuid, null: true
    add_index  :transactions, :refund_of_transaction_id
  end
end
