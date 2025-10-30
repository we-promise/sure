class AddExtraToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :extra, :jsonb, default: {}, null: false
    add_index :transactions, :extra, using: :gin
  end
end
