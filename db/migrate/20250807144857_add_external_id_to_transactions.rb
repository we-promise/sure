class AddExternalIdToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :external_id, :string
    add_index :transactions, :external_id
  end
end
