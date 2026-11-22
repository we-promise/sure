class AddJobTransactionsModifiedToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :job_transactions_modified, :integer, default: 0, null: false

    # On a run this finds still waiting on its AI jobs, transactions_modified
    # holds only what those jobs have reported, so up copies it to
    # job_transactions_modified.
    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE rule_runs SET job_transactions_modified = transactions_modified
          WHERE pending_jobs_count > 0
        SQL
      end
    end
  end
end
