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

  def async?
    true
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil, modified_transaction_ids: nil, already_modified_count: 0, async_jobs: nil)
    enrichable_transactions = transaction_scope.enrichable(:merchant_id)

    if enrichable_transactions.empty?
      Rails.logger.info("No transactions to auto-detect merchants for #{rule.id}")
      return 0
    end

    batch_size = Provider::LlmConcept.max_items_per_call
    jobs_count = 0
    enrichable_count = enrichable_transactions.count
    already_modified_ids = Array(modified_transaction_ids)

    enrichable_transactions.in_batches(of: batch_size).each_with_index do |transactions, idx|
      Rails.logger.info("Scheduling auto-merchant-enrichment for batch #{idx + 1} of #{enrichable_count}")
      enqueue = lambda do
        rule.family.auto_detect_transaction_merchants_later(
          transactions,
          rule_run_id: rule_run&.id,
          exclude_transaction_ids: already_modified_ids & transactions.pluck(:id),
          already_modified_count: already_modified_count
        )
      end
      if async_jobs
        async_jobs << enqueue
      else
        enqueue.call
      end
      jobs_count += 1
    end

    # The jobs report what they changed via rule_run.complete_job!, leaving out
    # the transactions the rule's other actions already changed. Rule#apply
    # collects them in async_jobs so the run records them before they enqueue.
    {
      async: true,
      jobs_count: jobs_count
    }
  end
end
