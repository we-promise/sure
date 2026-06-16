class Rule::ActionExecutor::AutoCategorize < Rule::ActionExecutor
  def label
    base_label = I18n.t("rules.actions.auto_categorize.label")

    if rule.family.self_hoster?
      llm_provider = Provider::Registry.preferred_llm_provider

      if llm_provider
        selected_model = Provider::Registry.effective_llm_model_for(llm_provider)
        estimated_cost = LlmUsage.estimate_auto_categorize_cost(
          transaction_count: 20,
          category_count: rule.family.categories.count,
          model: selected_model
        )
        suffix =
          if estimated_cost.nil?
            " (#{I18n.t("rules.actions.auto_categorize.cost_na")})"
          else
            " (#{I18n.t("rules.actions.auto_categorize.cost_estimate", cost: sprintf('%.4f', estimated_cost), count: 20)})"
          end
        "#{base_label}#{suffix}"
      else
        "#{base_label} (#{I18n.t("rules.actions.auto_categorize.no_provider")})"
      end
    else
      base_label
    end
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    enrichable_transactions = transaction_scope.enrichable(:category_id)

    if enrichable_transactions.empty?
      Rails.logger.info("No transactions to auto-categorize for #{rule.id}")
      return 0
    end

    batch_size = 20
    jobs_count = 0

    enrichable_transactions.in_batches(of: batch_size).each_with_index do |transactions, idx|
      Rails.logger.info("Scheduling auto-categorization for batch #{idx + 1} of #{enrichable_transactions.count}")
      rule.family.auto_categorize_transactions_later(transactions, rule_run_id: rule_run&.id)
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
