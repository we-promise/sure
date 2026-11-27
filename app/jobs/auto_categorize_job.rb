# Kept for one release so jobs queued before the upgrade still run: rule categorization is an
# Ai::GenerationRun now. The rule run already counted this job, so it isn't counted again; it ends
# when the run does.
class AutoCategorizeJob < ApplicationJob
  queue_as Ai::Routes::QUEUES.fetch(:background)

  # The rule run hears once, after the last try: a run told earlier could be ended twice.
  retry_on(StandardError, wait: :polynomially_longer, attempts: 5, report: true) do |job, error|
    args = job.arguments.last
    RuleRun.find_by(id: args[:rule_run_id])&.fail_job!(error:, source: job.class.name, transaction_ids: args[:transaction_ids])
  end
  # Again, as the handler declared last wins: a deleted family's job isn't retried.
  discard_on ActiveJob::DeserializationError

  def perform(family, transaction_ids: [], rule_run_id: nil)
    queued = family.auto_categorize_transactions_later(family.transactions.where(id: transaction_ids), rule_run_id:)
    raise ActiveJob::EnqueueError, "the categorization couldn't be queued" unless queued
  end
end
