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

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    protected_scope = protected_transactions(transaction_scope)
    cached_transaction_ids = cached_transaction_ids(protected_scope)
    blocked_transaction_ids = protected_scope.pluck(:id) - cached_transaction_ids

    log_cache_usage(cached_transaction_ids) if cached_transaction_ids.any?
    log_blocked_transactions(blocked_transaction_ids) if blocked_transaction_ids.any?

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

  private
    def protected_transactions(transaction_scope)
      transaction_scope.where(Arel.sql("transactions.locked_attributes ? :attribute"), attribute: "category_id")
    end

    def cached_transaction_ids(protected_scope)
      protected_scope
        .joins(:data_enrichments)
        .where(data_enrichments: { attribute_name: "category_id", source: "ai" })
        .where(Arel.sql("data_enrichments.value = to_jsonb(transactions.category_id::text)"))
        .distinct
        .pluck(:id)
    end

    def log_cache_usage(transaction_ids)
      DebugLogEntry.capture(
        category: "auto_categorization",
        level: "info",
        message: "AI categorization cache used",
        source: self.class.name,
        family: rule.family,
        metadata: {
          rule_id: rule.id,
          cached_transaction_ids: transaction_ids
        }
      )
    end

    def log_blocked_transactions(transaction_ids)
      DebugLogEntry.capture(
        category: "auto_categorization",
        level: "info",
        message: "AI categorization blocked by enrichment protection",
        source: self.class.name,
        family: rule.family,
        metadata: {
          rule_id: rule.id,
          blocked_transaction_ids: transaction_ids
        }
      )
    end
end
