class AddJobTransactionsModifiedToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :job_transactions_modified, :integer, default: 0, null: false
  end
end
