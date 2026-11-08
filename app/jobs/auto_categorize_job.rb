# Kept so a job queued before the upgrade still runs: it hands the work to Ai::GenerationJob.
# Nothing enqueues it any more.
class AutoCategorizeJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(family, transaction_ids: [], rule_run_id: nil)
    Ai::GenerationJob.perform_later(:categorize, { ids: transaction_ids, family_id: family.id, rule_run_id: }.compact)
  end
end
