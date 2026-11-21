# The ids an Ai::GenerationJob chain works through, one row per item, so each job carries a run id
# and a cursor and reads only its own window instead of passing every remaining id along (#5077).
class CreateAiGenerationRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_generation_runs, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :feature, null: false
      t.integer :item_count, null: false

      t.timestamps
    end
    add_index :ai_generation_runs, :created_at

    # No foreign key on item_id: it names a transaction or a merchant, depending on the feature.
    create_table :ai_generation_run_items, primary_key: [ :run_id, :position ] do |t|
      t.uuid :run_id, null: false
      t.integer :position, null: false
      t.uuid :item_id, null: false
    end
    add_foreign_key :ai_generation_run_items, :ai_generation_runs, column: :run_id, on_delete: :cascade
  end
end
