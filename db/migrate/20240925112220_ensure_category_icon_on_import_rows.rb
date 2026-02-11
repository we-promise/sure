class EnsureCategoryIconOnImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :category_icon, :string unless column_exists?(:import_rows, :category_icon)
  end
end
