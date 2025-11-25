class AddCategoryToTrades < ActiveRecord::Migration[7.2]
  def change
    add_reference :trades, :category, null: true, foreign_key: true, type: :uuid
  end
end
