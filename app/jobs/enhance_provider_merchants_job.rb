# Kept for one release so jobs queued before the upgrade still run: merchant enhancement is an
# Ai::GenerationRun now, over every merchant not yet enhanced, so a batch's merchant_ids aren't needed.
class EnhanceProviderMerchantsJob < ApplicationJob
  queue_as Ai::Routes::QUEUES.fetch(:background)

  def perform(family, merchant_ids: nil)
    ProviderMerchant::Enhancer.enhance_later(family)
  end
end
