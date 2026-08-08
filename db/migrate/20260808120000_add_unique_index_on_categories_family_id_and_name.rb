# frozen_string_literal: true

# Family#investment_contributions_category (and other find_or_create_by! paths)
# rescue ActiveRecord::RecordNotUnique, but that only fires when the DB has a
# unique constraint. Schema previously indexed family_id alone, so parallel
# sync/import jobs could create duplicate category names per family.
class AddUniqueIndexOnCategoriesFamilyIdAndName < ActiveRecord::Migration[7.2]
  INDEX_NAME = "index_categories_on_family_id_and_name"

  def up
    return if index_exists?(:categories, [ :family_id, :name ], unique: true, name: INDEX_NAME)

    say_with_time "Deduplicating categories with the same family_id and name" do
      dedupe_categories!
    end

    add_index :categories, [ :family_id, :name ], unique: true, name: INDEX_NAME
  end

  def down
    remove_index :categories, name: INDEX_NAME if index_exists?(:categories, name: INDEX_NAME)
  end

  private
    def dedupe_categories!
      execute <<~SQL.squish
        CREATE TEMPORARY TABLE category_dedupe_map AS
        WITH ranked AS (
          SELECT
            id,
            ROW_NUMBER() OVER (
              PARTITION BY family_id, name
              ORDER BY created_at ASC, id ASC
            ) AS row_num,
            FIRST_VALUE(id) OVER (
              PARTITION BY family_id, name
              ORDER BY created_at ASC, id ASC
            ) AS keeper_id
          FROM categories
        )
        SELECT id AS duplicate_id, keeper_id
        FROM ranked
        WHERE row_num > 1
      SQL

      # Point child categories at the keeper before deleting duplicates.
      execute <<~SQL.squish
        UPDATE categories AS children
        SET parent_id = map.keeper_id
        FROM category_dedupe_map AS map
        WHERE children.parent_id = map.duplicate_id
      SQL

      execute <<~SQL.squish
        UPDATE transactions
        SET category_id = map.keeper_id
        FROM category_dedupe_map AS map
        WHERE transactions.category_id = map.duplicate_id
      SQL

      # budget_categories has a unique (budget_id, category_id) index. Match
      # Category::Merger: fold duplicate budgeted_spending into the keeper row
      # before deleting collisions, then reassign non-colliding rows.
      execute <<~SQL.squish
        UPDATE budget_categories AS keeper_bc
        SET budgeted_spending = COALESCE(keeper_bc.budgeted_spending, 0) + dup_totals.total_spending
        FROM (
          SELECT
            map.keeper_id,
            bc.budget_id,
            SUM(COALESCE(bc.budgeted_spending, 0)) AS total_spending
          FROM budget_categories AS bc
          INNER JOIN category_dedupe_map AS map
            ON bc.category_id = map.duplicate_id
          WHERE EXISTS (
            SELECT 1
            FROM budget_categories AS existing_keeper
            WHERE existing_keeper.budget_id = bc.budget_id
              AND existing_keeper.category_id = map.keeper_id
          )
          GROUP BY map.keeper_id, bc.budget_id
        ) AS dup_totals
        WHERE keeper_bc.budget_id = dup_totals.budget_id
          AND keeper_bc.category_id = dup_totals.keeper_id
      SQL

      execute <<~SQL.squish
        DELETE FROM budget_categories AS bc
        USING category_dedupe_map AS map
        WHERE bc.category_id = map.duplicate_id
          AND EXISTS (
            SELECT 1
            FROM budget_categories AS keeper_bc
            WHERE keeper_bc.budget_id = bc.budget_id
              AND keeper_bc.category_id = map.keeper_id
          )
      SQL

      execute <<~SQL.squish
        UPDATE budget_categories
        SET category_id = map.keeper_id
        FROM category_dedupe_map AS map
        WHERE budget_categories.category_id = map.duplicate_id
      SQL

      execute <<~SQL.squish
        UPDATE import_mappings
        SET mappable_id = map.keeper_id
        FROM category_dedupe_map AS map
        WHERE import_mappings.mappable_type = 'Category'
          AND import_mappings.mappable_id = map.duplicate_id
      SQL

      execute <<~SQL.squish
        UPDATE rule_actions
        SET value = map.keeper_id::text
        FROM category_dedupe_map AS map
        WHERE rule_actions.value = map.duplicate_id::text
      SQL

      execute <<~SQL.squish
        UPDATE rule_conditions
        SET value = map.keeper_id::text
        FROM category_dedupe_map AS map
        WHERE rule_conditions.value = map.duplicate_id::text
      SQL

      execute <<~SQL.squish
        DELETE FROM categories
        USING category_dedupe_map AS map
        WHERE categories.id = map.duplicate_id
      SQL

      execute "DROP TABLE category_dedupe_map"
    end
end
