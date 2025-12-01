class AddDetailsToCategories < ActiveRecord::Migration[7.2]
  def change
    add_column :categories, :details, :text
  end
end
