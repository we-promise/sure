# Shadow comparisons for any feature: `ai_comparisons` replaces
# `categorization_comparisons`. Each old row is copied as a `categorize` comparison: the
# providers become the routes' endpoints, the category names become the family's category ids
# where one has that name, and the names and Jev's probabilities stay in `metadata`.
class MoveCategorizationComparisonsToAiComparisons < ActiveRecord::Migration[8.1]
  def up
    create_table :ai_comparisons, id: :uuid do |t|
      t.string :feature, null: false
      t.references :family, type: :uuid, null: false, foreign_key: true, index: false
      t.string :subject_type
      t.uuid :subject_id
      t.jsonb :primary_route, null: false, default: {}
      t.jsonb :shadow_route, null: false, default: {}
      t.string :primary_value
      t.string :shadow_value
      t.decimal :primary_confidence, precision: 5, scale: 4
      t.decimal :shadow_confidence, precision: 5, scale: 4
      t.boolean :agreed, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :ai_comparisons, %i[family_id feature agreed created_at], name: "index_ai_comparisons_on_family_feature_agreement"
    add_index :ai_comparisons, %i[subject_type subject_id]

    execute <<~SQL
      INSERT INTO ai_comparisons (id, feature, family_id, subject_type, subject_id, primary_route, shadow_route,
                                  primary_value, shadow_value, shadow_confidence, agreed, metadata, created_at, updated_at)
      SELECT c.id, 'categorize', c.family_id, CASE WHEN c.transaction_id IS NULL THEN NULL ELSE 'Transaction' END, c.transaction_id,
             jsonb_build_object('endpoint', c.applied_provider), jsonb_build_object('endpoint', c.shadow_provider),
             (SELECT cat.id::text FROM categories cat WHERE cat.family_id = c.family_id AND cat.name = c.applied_category_name ORDER BY cat.created_at LIMIT 1),
             (SELECT cat.id::text FROM categories cat WHERE cat.family_id = c.family_id AND cat.name = c.shadow_category_name ORDER BY cat.created_at LIMIT 1),
             c.shadow_confidence, c.agreed,
             jsonb_strip_nulls(jsonb_build_object(
               'primary_category_name', c.applied_category_name, 'shadow_category_name', c.shadow_category_name,
               'shadow_probabilities', NULLIF(c.shadow_probabilities, '{}'::jsonb))),
             c.created_at, c.updated_at
      FROM categorization_comparisons c
    SQL

    drop_table :categorization_comparisons
  end

  def down
    create_table :categorization_comparisons, id: :uuid do |t|
      t.boolean :agreed, null: false
      t.string :applied_category_name
      t.string :applied_provider, null: false
      t.uuid :family_id, null: false
      t.string :shadow_category_name
      t.decimal :shadow_confidence, precision: 5, scale: 4
      t.jsonb :shadow_probabilities, default: {}, null: false
      t.string :shadow_provider, null: false
      t.uuid :transaction_id
      t.timestamps
    end
    add_index :categorization_comparisons, %i[family_id agreed created_at], name: "index_categorization_comparisons_on_family_agreement"
    add_index :categorization_comparisons, :family_id
    add_index :categorization_comparisons, :transaction_id
    add_foreign_key :categorization_comparisons, :families
    add_foreign_key :categorization_comparisons, :transactions, on_delete: :nullify

    execute <<~SQL
      INSERT INTO categorization_comparisons (id, agreed, applied_category_name, applied_provider, family_id, shadow_category_name,
                                              shadow_confidence, shadow_probabilities, shadow_provider, transaction_id, created_at, updated_at)
      SELECT a.id, a.agreed,
             COALESCE(a.metadata->>'primary_category_name', (SELECT name FROM categories WHERE id::text = a.primary_value)),
             COALESCE(a.primary_route->>'endpoint', 'unknown'), a.family_id,
             COALESCE(a.metadata->>'shadow_category_name', (SELECT name FROM categories WHERE id::text = a.shadow_value)),
             a.shadow_confidence, COALESCE(a.metadata->'shadow_probabilities', '{}'::jsonb),
             COALESCE(a.shadow_route->>'endpoint', 'unknown'),
             (SELECT t.id FROM transactions t WHERE t.id = a.subject_id), a.created_at, a.updated_at
      FROM ai_comparisons a
      WHERE a.feature = 'categorize'
    SQL

    drop_table :ai_comparisons
  end
end
