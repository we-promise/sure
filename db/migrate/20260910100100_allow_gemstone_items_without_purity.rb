class AllowGemstoneItemsWithoutPurity < ActiveRecord::Migration[8.1]
  def change
    change_column_null :valuable_items, :purity, true
  end
end
