class AddFamilyNameIndexToTagsAndCategories < ActiveRecord::Migration[8.1]
  def up
    merge_duplicate_tags
    merge_duplicate_categories

    add_index :tags, [ :family_id, :name ], unique: true
    add_index :categories, [ :family_id, :name ], unique: true
  end

  def down
    remove_index :categories, [ :family_id, :name ]
    remove_index :tags, [ :family_id, :name ]
  end

  private
    def merge_duplicate_tags
      execute <<~SQL.squish
        WITH duplicate_tags AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM tags
        ),
        tag_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_tags
          WHERE id <> keeper_id
        )
        UPDATE import_mappings
        SET mappable_id = tag_map.keeper_id
        FROM tag_map
        WHERE import_mappings.mappable_type = 'Tag'
          AND import_mappings.mappable_id = tag_map.duplicate_id
      SQL

      execute <<~SQL.squish
        WITH duplicate_tags AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM tags
        ),
        tag_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_tags
          WHERE id <> keeper_id
        )
        UPDATE taggings
        SET tag_id = tag_map.keeper_id
        FROM tag_map
        WHERE taggings.tag_id = tag_map.duplicate_id
      SQL

      execute <<~SQL.squish
        WITH duplicate_tags AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM tags
        ),
        impacted_tags AS (
          SELECT DISTINCT keeper_id
          FROM duplicate_tags
          WHERE id <> keeper_id
        ),
        duplicate_taggings AS (
          SELECT id
          FROM (
            SELECT taggings.id,
                   ROW_NUMBER() OVER (
                     PARTITION BY taggings.tag_id, taggings.taggable_type, taggings.taggable_id
                     ORDER BY taggings.created_at, taggings.id
                   ) AS row_number
            FROM taggings
            JOIN impacted_tags ON taggings.tag_id = impacted_tags.keeper_id
          ) ranked_taggings
          WHERE row_number > 1
        )
        DELETE FROM taggings
        USING duplicate_taggings
        WHERE taggings.id = duplicate_taggings.id
      SQL

      execute <<~SQL.squish
        WITH duplicate_tags AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM tags
        ),
        tag_map AS (
          SELECT id AS duplicate_id
          FROM duplicate_tags
          WHERE id <> keeper_id
        )
        DELETE FROM tags
        USING tag_map
        WHERE tags.id = tag_map.duplicate_id
      SQL
    end

    def merge_duplicate_categories
      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE import_mappings
        SET mappable_id = category_map.keeper_id
        FROM category_map
        WHERE import_mappings.mappable_type = 'Category'
          AND import_mappings.mappable_id = category_map.duplicate_id
      SQL

      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE transactions
        SET category_id = category_map.keeper_id
        FROM category_map
        WHERE transactions.category_id = category_map.duplicate_id
      SQL

      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE categories
        SET parent_id = category_map.keeper_id
        FROM category_map
        WHERE categories.parent_id = category_map.duplicate_id
          AND categories.id <> category_map.keeper_id
      SQL

      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE categories
        SET parent_id = NULL
        FROM category_map
        WHERE categories.id = category_map.keeper_id
          AND categories.parent_id = category_map.duplicate_id
      SQL

      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        ),
        canonical_budget_categories AS (
          SELECT budget_categories.id,
                 budget_categories.budget_id,
                 budget_categories.category_id,
                 COALESCE(category_map.keeper_id, budget_categories.category_id) AS keeper_id,
                 budget_categories.budgeted_spending
          FROM budget_categories
          LEFT JOIN category_map ON budget_categories.category_id = category_map.duplicate_id
          WHERE category_map.keeper_id IS NOT NULL
             OR EXISTS (
               SELECT 1
               FROM category_map existing_map
               WHERE existing_map.keeper_id = budget_categories.category_id
             )
        ),
        duplicate_budget_category_totals AS (
          SELECT budget_id,
                 keeper_id,
                 SUM(budgeted_spending) AS budgeted_spending
          FROM canonical_budget_categories
          GROUP BY budget_id, keeper_id
          HAVING COUNT(*) > 1
        ),
        budget_category_keepers AS (
          SELECT id,
                 budget_id,
                 keeper_id,
                 ROW_NUMBER() OVER (
                   PARTITION BY budget_id, keeper_id
                   ORDER BY (category_id = keeper_id) DESC, id
                 ) AS row_number
          FROM canonical_budget_categories
        )
        UPDATE budget_categories
        SET budgeted_spending = duplicate_budget_category_totals.budgeted_spending
        FROM budget_category_keepers
        JOIN duplicate_budget_category_totals ON duplicate_budget_category_totals.budget_id = budget_category_keepers.budget_id
          AND duplicate_budget_category_totals.keeper_id = budget_category_keepers.keeper_id
        WHERE budget_categories.id = budget_category_keepers.id
          AND budget_category_keepers.row_number = 1
      SQL

      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        ),
        canonical_budget_categories AS (
          SELECT budget_categories.id,
                 budget_categories.budget_id,
                 budget_categories.category_id,
                 COALESCE(category_map.keeper_id, budget_categories.category_id) AS keeper_id
          FROM budget_categories
          LEFT JOIN category_map ON budget_categories.category_id = category_map.duplicate_id
          WHERE category_map.keeper_id IS NOT NULL
             OR EXISTS (
               SELECT 1
               FROM category_map existing_map
               WHERE existing_map.keeper_id = budget_categories.category_id
             )
        ),
        duplicate_budget_categories AS (
          SELECT id
          FROM (
            SELECT id,
                   ROW_NUMBER() OVER (
                     PARTITION BY budget_id, keeper_id
                     ORDER BY (category_id = keeper_id) DESC, id
                   ) AS row_number
            FROM canonical_budget_categories
          ) ranked_budget_categories
          WHERE row_number > 1
        )
        DELETE FROM budget_categories
        USING duplicate_budget_categories
        WHERE budget_categories.id = duplicate_budget_categories.id
      SQL

      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE budget_categories
        SET category_id = category_map.keeper_id
        FROM category_map
        WHERE budget_categories.category_id = category_map.duplicate_id
      SQL

      execute <<~SQL.squish
        WITH duplicate_categories AS (
          SELECT id, FIRST_VALUE(id) OVER (
            PARTITION BY family_id, name
            ORDER BY created_at, id
          ) AS keeper_id
          FROM categories
        ),
        category_map AS (
          SELECT id AS duplicate_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        DELETE FROM categories
        USING category_map
        WHERE categories.id = category_map.duplicate_id
      SQL
    end
end
