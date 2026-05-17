class AddExtraToTrades < ActiveRecord::Migration[7.2]
  def change
    add_column :trades, :extra, :jsonb, default: {}, null: false
    add_index :trades, :extra, using: :gin
  end
end
