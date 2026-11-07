# Feature key to requester class. Spelled out rather than registered as classes load, so a job
# can find its requester before Zeitwerk has loaded it; ai_routing_matrix_test checks each class
# declares the key it's listed under.
module Ai::Requesters
  CLASSES = {
    bill_setup: "RecurringTransaction::AiSetupSuggester",
    categorize: "Family::AutoCategorizer",
    detect_merchants: "Family::AutoMerchantDetector",
    enhance_merchants: "ProviderMerchant::Enhancer"
  }.freeze

  module_function

  def fetch(feature) = (overrides[feature.to_sym] || CLASSES.fetch(feature.to_sym)).then { _1.is_a?(String) ? _1.constantize : _1 }

  # For tests: a requester class for a feature, until reset.
  def overrides = @overrides ||= {}
end
