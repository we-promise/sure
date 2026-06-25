class AddFamilyNameIndexToTagsAndCategories < ActiveRecord::Migration[8.0]
  def change
    add_index :tags, [ :family_id, :name ]
    add_index :categories, [ :family_id, :name ]
  end
end
