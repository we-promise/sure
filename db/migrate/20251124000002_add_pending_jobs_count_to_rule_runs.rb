class AddPendingJobsCountToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :pending_jobs_count, :integer, default: 0, null: false
  end
end
