# The Bayes classifier (Settings → Classifier) as a rule action: categorizes
# the uncategorized matches it's sure of, in the rule's place in the order.
# Free, so offered without a provider. Never overrides a lock.
class Rule::ActionExecutor::BayesCategorize < Rule::ActionExecutor
  def label
    "Categorize with the classifier (no AI)"
  end

  def claimed_attributes
    [ :category_id ]
  end

  def reserves_claimed_attributes?
    false
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    rule.family.bayes_categorize_uncategorized(transaction_scope)
  end
end
