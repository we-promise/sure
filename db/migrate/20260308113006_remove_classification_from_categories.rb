class RemoveClassificationFromCategories < ActiveRecord::Migration[7.2]
  def up
    remove_column :categories, :classification
  end

  def down
    add_column :categories, :classification, :string, default: "expense", null: false
  end
end
