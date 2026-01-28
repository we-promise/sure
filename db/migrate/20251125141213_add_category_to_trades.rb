class AddCategoryToTrades < ActiveRecord::Migration[7.2]
  def change
    unless column_exists?(:trades, :category_id)
      add_reference :trades, :category, null: true, foreign_key: true, type: :uuid
    end
  end
end
