class AddTransactionsQueuedToRuleRuns < ActiveRecord::Migration[7.2]
  def change
    add_column :rule_runs, :transactions_queued, :integer, null: false, default: 0
  end
end
