class AddFamilyNameIndexToTagsAndCategories < ActiveRecord::Migration[7.2]
  def change
    add_index :tags, [ :family_id, :name ], unique: true
    add_index :categories, [ :family_id, :name ], unique: true
  end
end
