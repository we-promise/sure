class Rule::ActionExecutor::AutoCategorize < Rule::ActionExecutor
  def label
    base_label = "Auto-categorize transactions with AI"

    if rule.family.self_hoster?
      selected_model = Ai.plan(:categorize, family: rule.family)&.model&.name

      if selected_model.present?
        # Estimate cost for typical batch of 20 transactions
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
        "#{base_label} (no categorization provider configured)"
      end
    else
      base_label
    end
  end

  def claimed_attributes
    [ :category_id ]
  end

  # The AI runs later and only fills fields it can classify, so it leaves
  # them to rules further down, as it did before rules had an order.
  def reserves_claimed_attributes?
    false
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

    # One job for every transaction: Ai::GenerationJob sends one batch, sized for the model, and
    # queues the rest behind other families' work. The run reports back once, through
    # RuleRun#complete_job!, and counts transactions_awaiting_ai down as each batch is applied.
    count = enrichable_transactions.count
    Rails.logger.info("Scheduling auto-categorization for #{count} transactions")
    rule_run&.await_ai!(count)
    rule.family.auto_categorize_transactions_later(enrichable_transactions, rule_run_id: rule_run&.id)

    { async: true, modified_count: count, jobs_count: 1 }
  end

  private
    def protected_transactions(transaction_scope)
      transaction_scope.where(Arel.sql("transactions.locked_attributes ? :attribute"), attribute: "category_id")
    end

    def cached_transaction_ids(protected_scope)
      protected_scope.category_from("ai").pluck(:id)
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
