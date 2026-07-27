class AddLastUsedAtToCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :categories, :last_used_at, :datetime
    add_index :categories, [ :family_id, :last_used_at ]
  end
end
