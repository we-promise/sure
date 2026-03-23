class EnhanceProviderMerchantsJob < ApplicationJob
  queue_as :medium_priority

  def perform(family)
    ProviderMerchant::Enhancer.new(family).enhance
  end
end
