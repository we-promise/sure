class EnhanceProviderMerchantsJob < ApplicationJob
  queue_as :ai_low_priority

  # Without merchant_ids, queues one job per LLM call's worth of the family's
  # unenhanced merchants, like merchant detection.
  def perform(family, merchant_ids: nil)
    enhancer = ProviderMerchant::Enhancer.new(family, merchant_ids: merchant_ids)
    merchant_ids ? enhancer.enhance : enhancer.enhance_later
  ensure
    Rails.cache.delete("enhance_provider_merchants:#{family.id}")
  end
end
