# Feature key to requester class. Spelled out rather than registered as classes load, so a job
# can find its requester before Zeitwerk has loaded it; ai_routing_matrix_test checks each class
# declares the key it's listed under.
module Ai::Requesters
  CLASSES = {
    categorize: "Family::AutoCategorizer",
    detect_merchants: "Family::AutoMerchantDetector",
    enhance_merchants: "ProviderMerchant::Enhancer"
  }.freeze

  module_function

  def fetch(feature) = CLASSES.fetch(feature.to_sym).constantize
end
