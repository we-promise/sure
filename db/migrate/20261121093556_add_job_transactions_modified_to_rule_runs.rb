class AddJobTransactionsModifiedToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :job_transactions_modified, :integer, default: 0, null: false

    # Until now transactions_modified held only what a run's AI jobs changed,
    # so runs still waiting on their jobs carry it over.
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
