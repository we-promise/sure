class AddPendingJobsCountToRuleRuns < ActiveRecord::Migration[7.2]
  def change
    add_column :rule_runs, :pending_jobs_count, :integer, default: 0, null: false
  end
end
