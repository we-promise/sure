# Kept for one release so jobs queued before the upgrade still run: rule categorization is an
# Ai::GenerationRun now. The rule run already counted this job, so it isn't counted again; it ends
# when the run does.
class AutoCategorizeJob < ApplicationJob
  queue_as Ai::Routes::QUEUES.fetch(:background)

  def perform(family, transaction_ids: [], rule_run_id: nil)
    queued = family.auto_categorize_transactions_later(family.transactions.where(id: transaction_ids), rule_run_id:)
    raise ActiveJob::EnqueueError, "the categorization couldn't be queued" unless queued
  end
end
