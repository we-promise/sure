class Rule::ActionExecutor::AutoCategorize < Rule::ActionExecutor
  def label
    base_label = "Auto-categorize transactions with AI"

    if rule.family.self_hoster?
      # Use the same provider determination logic as Family::AutoCategorizer
      llm_provider = Provider::Registry.get_provider(:openai)

      if llm_provider
        # Estimate cost for typical batch of 20 transactions
        selected_model = Provider::Openai.effective_model
        estimated_cost = LlmUsage.estimate_auto_categorize_cost(
          transaction_count: 20,
          category_count: rule.family.categories.count,
          model: selected_model
        )
        suffix =
          if estimated_cost.nil?
            " (cost: N/A)"
          else
            " (~$#{sprintf('%.4f', estimated_cost)} per 20 transactions)"
          end
        "#{base_label}#{suffix}"
      else
        "#{base_label} (no LLM provider configured)"
      end
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
