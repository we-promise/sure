class AddFamilyNameIndexToTagsAndCategories < ActiveRecord::Migration[7.2]
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
        ),
        duplicate_taggings AS (
          SELECT taggings.id
          FROM taggings
          JOIN tag_map ON taggings.tag_id = tag_map.duplicate_id
          JOIN taggings existing ON existing.tag_id = tag_map.keeper_id
            AND existing.taggable_type = taggings.taggable_type
            AND existing.taggable_id = taggings.taggable_id
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
        duplicate_budget_categories AS (
          SELECT source.id AS source_id, target.id AS target_id
          FROM budget_categories source
          JOIN category_map ON source.category_id = category_map.duplicate_id
          JOIN budget_categories target ON target.budget_id = source.budget_id
            AND target.category_id = category_map.keeper_id
        ),
        duplicate_budget_category_totals AS (
          SELECT duplicate_budget_categories.target_id,
                 SUM(source.budgeted_spending) AS source_budgeted_spending,
                 MAX(source.updated_at) AS source_updated_at
          FROM duplicate_budget_categories
          JOIN budget_categories source ON source.id = duplicate_budget_categories.source_id
          GROUP BY duplicate_budget_categories.target_id
        )
        UPDATE budget_categories
        SET budgeted_spending = budget_categories.budgeted_spending + duplicate_budget_category_totals.source_budgeted_spending,
            updated_at = GREATEST(budget_categories.updated_at, duplicate_budget_category_totals.source_updated_at)
        FROM duplicate_budget_category_totals
        WHERE budget_categories.id = duplicate_budget_category_totals.target_id
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
        DELETE FROM budget_categories
        USING category_map
        WHERE budget_categories.category_id = category_map.duplicate_id
          AND EXISTS (
            SELECT 1
            FROM budget_categories target
            WHERE target.budget_id = budget_categories.budget_id
              AND target.category_id = category_map.keeper_id
          )
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
