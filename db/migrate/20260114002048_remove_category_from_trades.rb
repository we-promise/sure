class RemoveCategoryFromTrades < ActiveRecord::Migration[7.2]
  def change
    remove_column :trades, :category_id, :bigint
  end
end
