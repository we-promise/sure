class CreateEvalTables < ActiveRecord::Migration[7.2]
  def change
    # Eval Datasets - Golden dataset containers
    create_table :eval_datasets, id: :uuid do |t|
      t.string :name, null: false
      t.string :description
      t.string :eval_type, null: false
      t.string :version, null: false, default: "1.0"
      t.integer :sample_count, default: 0
      t.jsonb :metadata, default: {}
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :eval_datasets, :name, unique: true
    add_index :eval_datasets, [ :eval_type, :active ]

    # Eval Samples - Individual test cases
    create_table :eval_samples, id: :uuid do |t|
      t.references :eval_dataset, null: false, foreign_key: true, type: :uuid
      t.jsonb :input_data, null: false
      t.jsonb :expected_output, null: false
      t.jsonb :context_data, default: {}
      t.string :difficulty, default: "medium"
      t.string :tags, array: true, default: []
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :eval_samples, [ :eval_dataset_id, :difficulty ]
    add_index :eval_samples, :tags, using: :gin

    # Eval Runs - Evaluation execution records
    create_table :eval_runs, id: :uuid do |t|
      t.references :eval_dataset, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :status, null: false, default: "pending"
      t.string :provider, null: false
      t.string :model, null: false
      t.jsonb :provider_config, default: {}
      t.jsonb :metrics, default: {}
      t.integer :total_prompt_tokens, default: 0
      t.integer :total_completion_tokens, default: 0
      t.decimal :total_cost, precision: 10, scale: 6, default: 0.0
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error_message

      t.timestamps
    end

    add_index :eval_runs, [ :eval_dataset_id, :model ]
    add_index :eval_runs, [ :provider, :model ]
    add_index :eval_runs, :status

    # Eval Results - Individual sample results
    create_table :eval_results, id: :uuid do |t|
      t.references :eval_run, null: false, foreign_key: true, type: :uuid
      t.references :eval_sample, null: false, foreign_key: true, type: :uuid
      t.jsonb :actual_output, null: false
      t.boolean :correct, null: false
      t.boolean :exact_match, default: false
      t.boolean :hierarchical_match, default: false
      t.boolean :null_expected, default: false
      t.boolean :null_returned, default: false
      t.float :fuzzy_score
      t.integer :latency_ms
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.decimal :cost, precision: 10, scale: 6
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :eval_results, [ :eval_run_id, :correct ]
    # eval_sample_id index is automatically created by t.references
  end
end
