class EnsureCategoryFieldsOnImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :category_parent, :string unless column_exists?(:import_rows, :category_parent)
    add_column :import_rows, :category_color, :string unless column_exists?(:import_rows, :category_color)
    add_column :import_rows, :category_classification, :string unless column_exists?(:import_rows, :category_classification)
  end
end
