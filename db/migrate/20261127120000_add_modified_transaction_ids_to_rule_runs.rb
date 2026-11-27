class AddModifiedTransactionIdsToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :modified_transaction_ids, :jsonb, default: [], null: false
  end
end
