class Family::AutoCategorizer
  Error = Class.new(StandardError)

  def initialize(family, transaction_ids: [])
    @family = family
    @transaction_ids = transaction_ids
  end

  def auto_categorize
    raise Error, "No LLM provider for auto-categorization" unless categorization_provider

    protected_ids = protected_transaction_ids
    cached_ids = cached_transaction_ids
    blocked_ids = protected_ids - cached_ids
    log_cache_usage(cached_ids) if cached_ids.any?
    log_blocked_transactions(blocked_ids) if blocked_ids.any?

    if scope.none?
      Rails.logger.info("No transactions to auto-categorize for family #{family.id}")
      return 0
    else
      Rails.logger.info("Auto-categorizing #{scope.count} transactions for family #{family.id}")
    end

    categories_input = user_categories_input

    if categories_input.empty?
      message = "Cannot auto-categorize transactions for family #{family.id}: no categories available"
      Rails.logger.error(message)
      DebugLogEntry.capture(
        category: "auto_categorization",
        level: "error",
        message: "AI categorization failed: no categories available",
        source: self.class.name,
        family: family,
        provider: categorization_provider,
        metadata: {
          requested_transaction_ids: transaction_ids
        }
      )
      raise Error, "No categories available for auto-categorization"
    end

    result = categorization_provider.auto_categorize(
      transactions: transactions_input,
      user_categories: categories_input,
      family: family
    )

    unless result.success?
      raise Error, "Failed to auto-categorize transactions: #{result.error.message}"
    end

    modified_count = 0
    categorized_transaction_ids = []
    scope.each do |transaction|
      auto_categorization = result.data.find { |c| c.transaction_id == transaction.id }

      category_id = categories_input.find { |c| c[:name] == auto_categorization&.category_name }&.dig(:id)

      if category_id.present?
        categorized_transaction_ids << transaction.id
        was_modified = transaction.enrich_attribute(
          :category_id,
          category_id,
          source: "ai"
        )
        transaction.lock_attr!(:category_id)
        # enrich_attribute returns true if the transaction was actually modified
        modified_count += 1 if was_modified
      end
    end

    DebugLogEntry.capture(
      category: "auto_categorization",
      level: "info",
      message: "AI categorization completed",
      source: self.class.name,
      family: family,
      provider: categorization_provider,
      metadata: {
        requested_transaction_ids: transaction_ids,
        categorized_transaction_ids: categorized_transaction_ids,
        cached_transaction_ids: cached_ids,
        blocked_transaction_ids: blocked_ids,
        modified_count: modified_count
      }
    )

    modified_count
  end

  private
    attr_reader :family, :transaction_ids

    # Memoized: this is read once to guard, once per DebugLogEntry and once to
    # run, and each registry lookup builds a fresh provider object. Memoizing
    # also guarantees the provider named in the logs is the one that actually
    # ran, rather than whatever a later lookup happens to resolve.
    def categorization_provider
      return @categorization_provider if defined?(@categorization_provider)

      # Resolution lives on Family so the rule confirmation screen names the
      # same provider this run will use. The preview flag gates whether the
      # selector is offered at all (see
      # docs/llm-guides/gating-a-preview-feature.md); it plays no part here, so
      # a family that opted in and then chose the LLM provider gets the LLM
      # provider.
      @categorization_provider = family.resolved_categorization_provider
    end

    def user_categories_input
      family.categories.map do |category|
        {
          id: category.id,
          name: category.name,
          is_subcategory: category.subcategory?,
          parent_id: category.parent_id
        }
      end
    end

    def transactions_input
      scope.map do |transaction|
        {
          id: transaction.id,
          amount: transaction.entry.amount.abs,
          classification: transaction.entry.classification,
          description: [ transaction.entry.name, transaction.entry.notes ].compact.reject(&:empty?).join(" "),
          merchant: transaction.merchant&.name
        }
      end
    end

    def cached_transaction_ids
      protected_transactions
            .joins(:data_enrichments)
            .where(data_enrichments: { attribute_name: "category_id", source: "ai" })
            .where(Arel.sql("data_enrichments.value = to_jsonb(transactions.category_id::text)"))
            .distinct
            .pluck(:id)
    end

    def protected_transaction_ids
      protected_transactions.pluck(:id)
    end

    def protected_transactions
      family.transactions
            .where(id: transaction_ids)
            .where(Arel.sql("transactions.locked_attributes ? :attribute"), attribute: "category_id")
    end

    def log_cache_usage(cached_transaction_ids)
      DebugLogEntry.capture(
        category: "auto_categorization",
        level: "info",
        message: "AI categorization cache used",
        source: self.class.name,
        family: family,
        metadata: {
          cached_transaction_ids: cached_transaction_ids
        }
      )
    end

    def log_blocked_transactions(blocked_transaction_ids)
      DebugLogEntry.capture(
        category: "auto_categorization",
        level: "info",
        message: "AI categorization blocked by enrichment protection",
        source: self.class.name,
        family: family,
        metadata: {
          blocked_transaction_ids: blocked_transaction_ids
        }
      )
    end

    def scope
      family.transactions.where(id: transaction_ids, category_id: nil)
                         .enrichable(:category_id)
                         .includes(:category, :merchant, :entry)
    end
end
