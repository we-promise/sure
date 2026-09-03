class AddRefundFlagToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :refund, :boolean, default: false, null: false
  end
end
