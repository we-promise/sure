class AddWasMergedToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :was_merged, :boolean, null: false, default: false
  end
end
