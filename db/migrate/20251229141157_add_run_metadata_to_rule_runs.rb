class AddRunMetadataToRuleRuns < ActiveRecord::Migration[7.2]
  def change
    add_column :rule_runs, :run_metadata, :jsonb, default: {}
  end
end
