class CreateCategorizationComparisons < ActiveRecord::Migration[8.1]
  def change
    create_table :categorization_comparisons, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      # Nullified rather than cascaded: a comparison stays meaningful for
      # analysis after the transaction it described is gone.
      t.references :transaction, null: true, foreign_key: { on_delete: :nullify }, type: :uuid

      t.string :applied_provider, null: false
      t.string :applied_category_name
      t.string :shadow_provider, null: false
      t.string :shadow_category_name
      # Null whenever the shadow provider reports no confidence — the LLM
      # providers never do.
      t.decimal :shadow_confidence, precision: 5, scale: 4
      t.jsonb :shadow_probabilities, default: {}, null: false

      t.boolean :agreed, null: false

      t.timestamps
    end

    # The analysis query is "show me where they disagreed, most recent first".
    add_index :categorization_comparisons, [ :family_id, :agreed, :created_at ],
              name: "index_categorization_comparisons_on_family_agreement"
  end
end
