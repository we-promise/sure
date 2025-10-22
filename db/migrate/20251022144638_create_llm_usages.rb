class CreateLlmUsages < ActiveRecord::Migration[7.2]
  def change
    create_table :llm_usages, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :provider, null: false
      t.string :model, null: false
      t.string :operation, null: false
      t.integer :prompt_tokens, null: false, default: 0
      t.integer :completion_tokens, null: false, default: 0
      t.integer :total_tokens, null: false, default: 0
      t.decimal :estimated_cost, precision: 10, scale: 6, null: false, default: 0.0
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :llm_usages, [ :family_id, :created_at ]
    add_index :llm_usages, [ :family_id, :operation ]
  end
end
