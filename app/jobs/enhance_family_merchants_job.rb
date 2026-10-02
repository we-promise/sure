class EnhanceFamilyMerchantsJob < ApplicationJob
  queue_as :medium_priority

  def perform(family)
    FamilyMerchant::Enhancer.new(family).enhance
  ensure
    Rails.cache.delete("enhance_family_merchants:#{family.id}")
  end
end
