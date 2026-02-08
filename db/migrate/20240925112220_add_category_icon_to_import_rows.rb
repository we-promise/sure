class AddCategoryIconToImportRows < ActiveRecord::Migration[7.1]
  def change
    add_column :import_rows, :category_icon, :string
  end
end
