class AddSettledJobIdsToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :settled_job_ids, :string, array: true, default: [], null: false
  end
end
