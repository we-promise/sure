class AddCategoryFieldsToImportRows < ActiveRecord::Migration[7.1]
  def change
    add_column :import_rows, :category_parent, :string
    add_column :import_rows, :category_color, :string
    add_column :import_rows, :category_classification, :string
  end
end
