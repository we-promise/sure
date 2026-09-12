class AddRefundOfToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_reference :transactions, :refund_of, type: :uuid,
      foreign_key: { to_table: :transactions, on_delete: :nullify }
  end
end
