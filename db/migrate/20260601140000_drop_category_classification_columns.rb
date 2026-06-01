class DropCategoryClassificationColumns < ActiveRecord::Migration[7.2]
  def up
    remove_column :categories, :classification_unused if column_exists?(:categories, :classification_unused)
    remove_column :import_rows, :category_classification if column_exists?(:import_rows, :category_classification)
  end

  def down
    unless column_exists?(:categories, :classification_unused)
      add_column :categories, :classification_unused, :string, default: "expense", null: false
    end

    unless column_exists?(:import_rows, :category_classification)
      add_column :import_rows, :category_classification, :string
    end
  end
end
