class MergeDuplicateTagAndCategoryNames < ActiveRecord::Migration[7.2]
  def up
    merge_duplicate_tags
    merge_duplicate_categories
  end

  def down
    # Data merges are intentionally not undone.
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
        UPDATE import_source_mappings
        SET target_id = tag_map.keeper_id
        FROM tag_map
        WHERE import_source_mappings.target_type = 'Tag'
          AND import_source_mappings.target_id = tag_map.duplicate_id
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
        UPDATE rule_actions
        SET value = tag_map.keeper_id
        FROM tag_map
        WHERE rule_actions.action_type = 'set_transaction_tags'
          AND rule_actions.value = tag_map.duplicate_id::text
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
        UPDATE rule_conditions
        SET value = tag_map.keeper_id
        FROM tag_map
        WHERE rule_conditions.condition_type = 'transaction_tag'
          AND rule_conditions.value = tag_map.duplicate_id::text
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
        WITH #{duplicate_categories_cte},
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
        WITH #{duplicate_categories_cte},
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE import_source_mappings
        SET target_id = category_map.keeper_id
        FROM category_map
        WHERE import_source_mappings.target_type = 'Category'
          AND import_source_mappings.target_id = category_map.duplicate_id
      SQL

      execute <<~SQL.squish
        WITH #{duplicate_categories_cte},
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE rule_actions
        SET value = category_map.keeper_id
        FROM category_map
        WHERE rule_actions.action_type = 'set_transaction_category'
          AND rule_actions.value = category_map.duplicate_id::text
      SQL

      execute <<~SQL.squish
        WITH #{duplicate_categories_cte},
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        )
        UPDATE rule_conditions
        SET value = category_map.keeper_id
        FROM category_map
        WHERE rule_conditions.condition_type = 'transaction_category'
          AND rule_conditions.value = category_map.duplicate_id::text
      SQL

      execute <<~SQL.squish
        WITH #{duplicate_categories_cte},
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
        WITH #{duplicate_categories_cte},
        category_map AS (
          SELECT id AS duplicate_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        ),
        category_links AS (
          SELECT categories.id,
                 CASE
                   WHEN keepers.parent_id IS NULL THEN category_map.keeper_id
                   ELSE NULL
                 END AS parent_id
          FROM categories
          JOIN category_map ON categories.parent_id = category_map.duplicate_id
          JOIN categories keepers ON keepers.id = category_map.keeper_id
          WHERE categories.id <> category_map.keeper_id
        )
        UPDATE categories
        SET parent_id = category_links.parent_id
        FROM category_links
        WHERE categories.id = category_links.id
      SQL

      execute <<~SQL.squish
        WITH #{duplicate_categories_cte},
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
        WITH #{duplicate_categories_cte},
        category_map AS (
          SELECT id AS category_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
          UNION
          SELECT keeper_id AS category_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        ),
        grouped_budget_categories AS (
          SELECT budget_categories.id,
                 budget_categories.budget_id,
                 budget_categories.category_id,
                 budget_categories.budgeted_spending,
                 budget_categories.created_at,
                 budget_categories.updated_at,
                 category_map.keeper_id,
                 FIRST_VALUE(budget_categories.id) OVER (
                   PARTITION BY budget_categories.budget_id, category_map.keeper_id
                   ORDER BY CASE WHEN budget_categories.category_id = category_map.keeper_id THEN 0 ELSE 1 END,
                            budget_categories.created_at,
                            budget_categories.id
                 ) AS keeper_budget_category_id
          FROM budget_categories
          JOIN category_map ON budget_categories.category_id = category_map.category_id
        ),
        merged_budget_categories AS (
          SELECT keeper_budget_category_id,
                 keeper_id,
                 SUM(budgeted_spending) AS budgeted_spending,
                 MAX(updated_at) AS updated_at
          FROM grouped_budget_categories
          GROUP BY keeper_budget_category_id, keeper_id
        )
        UPDATE budget_categories
        SET category_id = merged_budget_categories.keeper_id,
            budgeted_spending = merged_budget_categories.budgeted_spending,
            updated_at = GREATEST(budget_categories.updated_at, merged_budget_categories.updated_at)
        FROM merged_budget_categories
        WHERE budget_categories.id = merged_budget_categories.keeper_budget_category_id
      SQL

      execute <<~SQL.squish
        WITH #{duplicate_categories_cte},
        category_map AS (
          SELECT id AS category_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
          UNION
          SELECT keeper_id AS category_id, keeper_id
          FROM duplicate_categories
          WHERE id <> keeper_id
        ),
        grouped_budget_categories AS (
          SELECT budget_categories.id,
                 category_map.keeper_id,
                 FIRST_VALUE(budget_categories.id) OVER (
                   PARTITION BY budget_categories.budget_id, category_map.keeper_id
                   ORDER BY CASE WHEN budget_categories.category_id = category_map.keeper_id THEN 0 ELSE 1 END,
                            budget_categories.created_at,
                            budget_categories.id
                 ) AS keeper_budget_category_id
          FROM budget_categories
          JOIN category_map ON budget_categories.category_id = category_map.category_id
        )
        DELETE FROM budget_categories
        USING grouped_budget_categories
        WHERE budget_categories.id = grouped_budget_categories.id
          AND budget_categories.id <> grouped_budget_categories.keeper_budget_category_id
      SQL

      execute <<~SQL.squish
        WITH #{duplicate_categories_cte},
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

    def duplicate_categories_cte
      <<~SQL.squish
        duplicate_categories AS (
          SELECT category_candidates.id,
                 FIRST_VALUE(category_candidates.id) OVER (
                   PARTITION BY category_candidates.family_id, category_candidates.name
                   ORDER BY CASE
                              WHEN category_candidates.group_has_children AND category_candidates.parent_id IS NULL THEN 0
                              WHEN category_candidates.group_has_children THEN 1
                              ELSE 0
                            END,
                            category_candidates.created_at,
                            category_candidates.id
                 ) AS keeper_id
          FROM (
            SELECT categories.id,
                   categories.family_id,
                   categories.name,
                   categories.parent_id,
                   categories.created_at,
                   EXISTS (
                     SELECT 1
                     FROM categories matching_categories
                     JOIN categories child_categories ON child_categories.parent_id = matching_categories.id
                     WHERE matching_categories.family_id = categories.family_id
                       AND matching_categories.name = categories.name
                   ) AS group_has_children
            FROM categories
          ) category_candidates
        )
      SQL
    end
end
