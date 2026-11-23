# How many of a rule run's transactions still wait for an AI answer. One AI job now carries every
# transaction and re-queues itself per batch, so pending_jobs_count no longer counts down;
# this does, per batch.
class AddTransactionsAwaitingAiToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :transactions_awaiting_ai, :integer, null: false, default: 0
  end
end
