class Rule::ActionExecutor::AutoDetectMerchants < Rule::ActionExecutor
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

    # One job for every transaction: Ai::GenerationJob sends one batch, sized for the model, and
    # queues the rest behind other families' work. The run reports back once, through
    # RuleRun#complete_job!, and counts transactions_awaiting_ai down as each batch is applied.
    count = enrichable_transactions.count
    Rails.logger.info("Scheduling auto-merchant-enrichment for #{count} transactions")
    rule_run&.await_ai!(count)
    rule.family.auto_detect_transaction_merchants_later(enrichable_transactions, rule_run_id: rule_run&.id)

    { async: true, modified_count: count, jobs_count: 1 }
  end
end
