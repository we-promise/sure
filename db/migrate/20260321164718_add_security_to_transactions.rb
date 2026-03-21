class AddSecurityToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_reference :transactions, :security, null: true, foreign_key: true, type: :uuid
  end
end
