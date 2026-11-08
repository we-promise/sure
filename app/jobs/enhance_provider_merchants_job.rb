# Kept so a job queued before the upgrade still runs: it hands the work to Ai::GenerationJob.
# Nothing enqueues it any more.
class EnhanceProviderMerchantsJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(family, merchant_ids: nil)
    Ai::GenerationJob.perform_later(:enhance_merchants, { family_id: family.id, ids: merchant_ids }.compact)
  end
end
