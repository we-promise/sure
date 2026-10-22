class AddCategoriesLockedToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :categories_locked, :boolean, default: false, null: false
  end
end
