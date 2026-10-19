# Bayes over the uncategorized transactions: after a sync (apply_rules:
# true, which then queues the rules so they see its categories) and from
# Settings → Classifier's Run. After a sync a failure is logged rather than
# raised, so the rules still run once and a retry doesn't queue them again.
class BayesCategorizeJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, apply_rules: false)
    family.bayes_categorize_uncategorized
  rescue => e
    raise unless apply_rules

    DebugLogEntry.capture(
      category: "auto_categorization",
      level: "error",
      message: "Bayesian categorization after sync failed: #{e.class}: #{e.message}",
      source: self.class.name,
      family: family,
      metadata: { error_class: e.class.name, error_message: e.message }
    )
  ensure
    ApplyRulesJob.perform_later(family) if apply_rules
  end
end
