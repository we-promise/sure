class BayesCategorizeJob < ApplicationJob
  queue_as :low_priority

  def perform(family)
    family.bayes_categorize_uncategorized
  end
end
