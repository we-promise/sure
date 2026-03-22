class RemoveClassificationFromCategories < ActiveRecord::Migration[7.2]
  def up
    rename_column :categories, :classification, :classification_unused
  end

  def down
    rename_column :categories, :classification_unused, :classification
  end
end
