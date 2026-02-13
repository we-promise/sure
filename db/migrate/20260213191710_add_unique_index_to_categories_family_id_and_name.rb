class AddUniqueIndexToCategoriesFamilyIdAndName < ActiveRecord::Migration[7.2]
  def up
    # First, identify and merge duplicate categories
    # This handles legacy data where categories might have been created with different locale names
    duplicates = execute(<<~SQL).to_a
      SELECT family_id, name, array_agg(id::text ORDER BY created_at) as ids
      FROM categories
      GROUP BY family_id, name
      HAVING COUNT(*) > 1
    SQL

    duplicates.each do |row|
      family_id = row["family_id"]
      name = row["name"]
      ids = row["ids"].tr("{}", "").split(",")
      keeper_id = ids.first
      duplicate_ids = ids[1..]

      next if duplicate_ids.empty?

      say "Merging duplicate categories for family #{family_id}, name '#{name}'"
      say "  Keeping: #{keeper_id}"
      say "  Removing: #{duplicate_ids.join(', ')}"

      # Update all transactions to point to the keeper category
      execute(<<~SQL)
        UPDATE transactions
        SET category_id = '#{keeper_id}'
        WHERE category_id IN (#{duplicate_ids.map { |id| "'#{id}'" }.join(', ')})
      SQL

      # Update all budget_categories to point to the keeper category
      execute(<<~SQL)
        UPDATE budget_categories
        SET category_id = '#{keeper_id}'
        WHERE category_id IN (#{duplicate_ids.map { |id| "'#{id}'" }.join(', ')})
      SQL

      # Update all subcategories to point to the keeper as parent
      execute(<<~SQL)
        UPDATE categories
        SET parent_id = '#{keeper_id}'
        WHERE parent_id IN (#{duplicate_ids.map { |id| "'#{id}'" }.join(', ')})
      SQL

      # Delete the duplicate categories
      execute(<<~SQL)
        DELETE FROM categories
        WHERE id IN (#{duplicate_ids.map { |id| "'#{id}'" }.join(', ')})
      SQL
    end

    # Now add the unique index
    add_index :categories, [ :family_id, :name ], unique: true, name: "index_categories_on_family_id_and_name_unique"
  end

  def down
    remove_index :categories, name: "index_categories_on_family_id_and_name_unique"
  end
end
