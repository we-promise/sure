class RemoveClassificationFromCategories < ActiveRecord::Migration[7.2]
  def up
    remove_column :categories, :classification
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Cannot restore classification column — original per-category values (income/expense) were not preserved"
  end
end
