class EnhanceProviderMerchantsJob < ApplicationJob
  queue_as :ai_low_priority

  # Set by FamilyMerchantsController#enhance so a second click doesn't queue the same merchants again.
  LOCK_TTL = 10.minutes

  def self.lock_key(family)
    "enhance_provider_merchants:#{family.id}"
  end

  # Without merchant_ids, queues one job per LLM call's worth of the family's
  # unenhanced merchants, like merchant detection. The lock then holds the
  # number of those jobs, and the last one to finish releases it.
  def perform(family, merchant_ids: nil)
    key = self.class.lock_key(family)

    if merchant_ids
      ProviderMerchant::Enhancer.new(family, merchant_ids: merchant_ids).enhance
      Rails.cache.delete(key) if Rails.cache.decrement(key, 1, expires_in: LOCK_TTL).to_i <= 0
    else
      batches = ProviderMerchant::Enhancer.new(family).batches
      return Rails.cache.delete(key) if batches.empty?

      Rails.cache.write(key, batches.size, raw: true, expires_in: LOCK_TTL)
      batches.each { |ids| self.class.perform_later(family, merchant_ids: ids) }
    end
  end
end
