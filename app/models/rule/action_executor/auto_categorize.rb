class Rule::ActionExecutor::AutoCategorize < Rule::ActionExecutor
  def label
    base_label = "Auto-categorize transactions with AI"

    if rule.family.self_hoster?
      # Estimate cost for typical batch of 20 transactions
      estimated_cost = LlmUsage.estimate_auto_categorize_cost(
        transaction_count: 20,
        category_count: rule.family.categories.count,
        model: Provider::Openai::DEFAULT_MODEL
      )
      "#{base_label} (~$#{sprintf('%.4f', estimated_cost)} per 20 transactions)"
    else
      base_label
    end
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false)
    enrichable_transactions = transaction_scope.enrichable(:category_id)

    if enrichable_transactions.empty?
      Rails.logger.info("No transactions to auto-categorize for #{rule.id}")
      return
    end

    enrichable_transactions.in_batches(of: 20).each_with_index do |transactions, idx|
      Rails.logger.info("Scheduling auto-categorization for batch #{idx + 1} of #{enrichable_transactions.count}")
      rule.family.auto_categorize_transactions_later(transactions)
    end
  end
end
