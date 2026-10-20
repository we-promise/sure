# The merchant matcher (Settings → Classifier) as a rule action: copies a
# missing merchant from near-duplicates, in the rule's place in the order.
# Free, so offered without a provider. Never overrides a lock.
class Rule::ActionExecutor::FillSimilarMerchants < Rule::ActionExecutor
  def label
    "Fill missing merchants from similar transactions (no AI)"
  end

  def claimed_attributes
    [ :merchant_id ]
  end

  def reserves_claimed_attributes?
    false
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    rule.family.fill_similar_merchants(transaction_scope)
  end
end
