class Rule::ActionExecutor::AutoDetectMerchants < Rule::ActionExecutor
  include Rule::AiEnrichment

  def label
    if rule.family.self_hoster?
      "Auto-detect merchants with AI ($$)"
    else
      "Auto-detect merchants"
    end
  end

  def claimed_attributes
    [ :merchant_id ]
  end

  # The AI runs later and only fills fields it can classify, so it leaves
  # them to rules further down, as it did before rules had an order.
  def reserves_claimed_attributes?
    false
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    enrichable_transactions = transaction_scope.enrichable(:merchant_id)

    if enrichable_transactions.empty?
      Rails.logger.info("No transactions to auto-detect merchants for #{rule.id}")
      return 0
    end

    Rails.logger.info("Scheduling auto-merchant-enrichment for #{enrichable_transactions.count} transactions")
    queue_ai_jobs(enrichable_transactions, rule_run:) do |transactions|
      rule.family.auto_detect_transaction_merchants_later(transactions, rule_run_id: rule_run&.id)
    end

    # modified_count is the queued count: the jobs report what they actually
    # changed through rule_run.complete_job!
    { async: true, modified_count: enrichable_transactions.count }
  end
end
