class CreateRuleRuns < ActiveRecord::Migration[7.2]
  def change
    create_table :rule_runs, id: :uuid do |t|
      t.references :rule, null: false, foreign_key: true, type: :uuid
      t.string :rule_name
      t.string :execution_type, null: false
      t.string :status, null: false
      t.integer :transactions_queued, null: false, default: 0
      t.integer :transactions_processed, null: false, default: 0
      t.integer :transactions_modified, null: false, default: 0
      t.integer :pending_jobs_count, null: false, default: 0
      t.datetime :executed_at, null: false
      t.text :error_message

      t.timestamps
    end

    add_index :rule_runs, :executed_at
    add_index :rule_runs, [ :rule_id, :executed_at ]
  end
end
