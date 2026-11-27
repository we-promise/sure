# Settings → Classifier's Run: the matcher (when its rule is on), then Bayes,
# over the uncategorized transactions, outside the rule order. After a sync
# they run as rules (Merchant matcher, Category classifier).
class BayesCategorizeJob < ApplicationJob
  queue_as :medium_priority

  def perform(family)
    family.fill_similar_merchants if family.classifier_rule_active?("fill_similar_merchants")
    family.bayes_categorize_uncategorized
  end
end
