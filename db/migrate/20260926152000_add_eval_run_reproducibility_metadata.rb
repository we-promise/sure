class AddEvalRunReproducibilityMetadata < ActiveRecord::Migration[8.1]
  def change
    add_column :eval_runs, :dataset_version, :string
    add_column :eval_runs, :resolved_model_snapshot, :string
  end
end
