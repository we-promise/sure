class AddTransferIdToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_reference :transactions, :transfer, null: true, foreign_key: true, type: :uuid
  end
end
