class Rule::ActionExecutor::AutoDetectMerchants < Rule::ActionExecutor
  def label
    if rule.family.self_hoster?
      "Auto-detect merchants with AI ($$)"
    else
      "Auto-detect merchants"
    end
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    enrichable_transactions = transaction_scope.enrichable(:merchant_id)

    if enrichable_transactions.empty?
      Rails.logger.info("No transactions to auto-detect merchants for #{rule.id}")
      return 0
    end

    batch_size = 20
    jobs_count = 0

    enrichable_transactions.in_batches(of: batch_size).each_with_index do |transactions, idx|
      Rails.logger.info("Scheduling auto-merchant-enrichment for batch #{idx + 1} of #{enrichable_transactions.count}")
      rule.family.auto_detect_transaction_merchants_later(transactions, rule_run_id: rule_run&.id)
      jobs_count += 1
    end

    # Return metadata about async jobs
    # Note: modified_count is set to queued_count here because we don't know
    # the actual modified count until the async jobs complete
    # The actual modified count will be reported back via rule_run.complete_job!
    {
      async: true,
      modified_count: enrichable_transactions.count,
      jobs_count: jobs_count
    }
  end
end
