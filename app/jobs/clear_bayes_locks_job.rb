class ClearBayesLocksJob < ApplicationJob
  queue_as :low_priority

  def perform(family)
    count = family.clear_bayes_locks!

    DebugLogEntry.capture(
      category: "auto_categorization",
      level: "info",
      message: "Cleared #{count} Bayes #{'lock'.pluralize(count)}",
      source: self.class.name,
      family: family,
      metadata: { unlocked_count: count }
    )
  end
end
