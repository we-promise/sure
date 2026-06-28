class AddRefundFlagToTransactions < ActiveRecord::Migration[7.2]
  def up
    add_column :transactions, :refund, :boolean, default: false, null: false

    Transaction.where(kind: "refund").update_all(refund: true, kind: "standard")
  end

  def down
    Transaction.where(refund: true).update_all(kind: "refund", refund: false)

    remove_column :transactions, :refund
  end
end
