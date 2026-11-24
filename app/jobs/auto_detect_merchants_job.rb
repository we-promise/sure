# Kept for one release so jobs queued before the upgrade still run: rule merchant detection is an
# Ai::GenerationRun now. The rule run already counted this job, so it isn't counted again; it ends
# when the run does.
class AutoDetectMerchantsJob < ApplicationJob
  queue_as Ai::Routes::QUEUES.fetch(:background)

  # The rule run hears once, after the last try: a run told earlier could be ended twice.
  retry_on(ActiveJob::EnqueueError, wait: :polynomially_longer, attempts: 5) do |job, error|
    args = job.arguments.last
    RuleRun.find_by(id: args[:rule_run_id])&.fail_job!(error:, source: job.class.name, transaction_ids: args[:transaction_ids])
  end

  def perform(family, transaction_ids: [], rule_run_id: nil)
    queued = begin
      family.auto_detect_transaction_merchants_later(family.transactions.where(id: transaction_ids), rule_run_id:)
    rescue StandardError => error
      # A queue adapter raises its own errors (Redis down); retry_on handles one kind.
      Rails.error.report(error, handled: true)
      false
    end
    raise ActiveJob::EnqueueError, "the merchant detection couldn't be queued" unless queued
  end
end
