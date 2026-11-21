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

    batch_size = Provider::LlmConcept.max_items_per_call
    jobs_count = 0

    enrichable_transactions.in_batches(of: batch_size).each_with_index do |transactions, idx|
      Rails.logger.info("Scheduling auto-merchant-enrichment for batch #{idx + 1} of #{enrichable_transactions.count}")
      rule.family.auto_detect_transaction_merchants_later(transactions, rule_run_id: rule_run&.id)
      jobs_count += 1
    end

    # The jobs report what they changed via rule_run.complete_job!
    {
      async: true,
      jobs_count: jobs_count
    }
  end
end
