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

    shadow_decisions = run_shadow(categories_input)

    modified_count = 0
    categorized_transaction_ids = []
    withheld = []

    scope.each do |transaction|
      auto_categorization = result.data.find { |c| c.transaction_id == transaction.id }

      category_id = categories_input.find { |c| c[:name] == auto_categorization&.category_name }&.dig(:id)

      next if category_id.blank?

      # Withheld rather than applied: the transaction is left unlocked and still
      # enrichable, so a later run (or a better model) can try again. Applying a
      # coin-flip guess and locking it would be worse than leaving it blank,
      # because the lock is what stops anything else from correcting it.
      if withhold?(auto_categorization)
        withheld << {
          transaction_id: transaction.id,
          category_name: auto_categorization.category_name,
          confidence: confidence_for(auto_categorization)
        }
        next
      end

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

    record_shadow_comparisons(result.data, shadow_decisions) if shadow_decisions

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
        modified_count: modified_count,
        confidence_threshold: family.effective_categorization_confidence_threshold,
        withheld_low_confidence: withheld,
        shadow_compared_count: shadow_decisions ? shadow_decisions.size : 0
      }.compact
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

    # Only providers reporting calibrated confidence can be gated. The LLM
    # providers return a bare category name, so there is nothing to compare and
    # their answers always apply — a threshold must not silently suppress a
    # provider it cannot measure.
    def confidence_for(decision)
      decision.confidence if decision.respond_to?(:confidence)
    end

    # Gated on the decision TYPE, not on whether a confidence happens to be
    # present. Keying on nil conflated two different situations: the LLM
    # providers return a bare category name and must never be gated on a
    # confidence they cannot produce, but a classification provider's answer
    # arriving without one is malformed and should be withheld, not applied.
    # `to_f` turns that nil into 0, so it falls below any positive threshold.
    def withhold?(decision)
      threshold = family.effective_categorization_confidence_threshold
      return false unless threshold.positive?
      return false unless decision.is_a?(Provider::ClassificationConcept::CategoryDecision)

      confidence_for(decision).to_f < threshold
    end

    # Asks the provider that is NOT in use to categorize the same batch, so it
    # can be judged on real data before anyone switches. Its answers are never
    # applied.
    #
    # Sampled per run rather than per transaction because the LLM providers
    # categorize a whole batch in one request — sampling individual rows would
    # not reduce the number of calls. Any failure is swallowed: a diagnostic
    # must never break the categorization it is observing.
    def run_shadow(categories_input)
      rate = family.effective_categorization_shadow_rate
      return nil unless rate.positive?
      return nil unless rand < rate

      provider = family.shadow_categorization_provider
      return nil if provider.nil? || provider.class == categorization_provider.class

      response = provider.auto_categorize(
        transactions: transactions_input,
        user_categories: categories_input,
        family: family
      )

      return nil unless response.success?

      @shadow_provider = provider
      response.data
    rescue => error
      Rails.logger.warn("Shadow categorization failed for family #{family.id}: #{error.class}: #{error.message}")
      nil
    end

    # Built from the decision lists rather than from `scope`, which is a fresh
    # query: by this point the applied answers have been written and locked, so
    # re-running it would match nothing.
    def record_shadow_comparisons(applied_decisions, shadow_decisions)
      ids = (applied_decisions.map(&:transaction_id) + shadow_decisions.map(&:transaction_id)).uniq

      rows = ids.filter_map do |id|
        applied = applied_decisions.find { |d| d.transaction_id == id }
        shadow = shadow_decisions.find { |d| d.transaction_id == id }
        next if applied.nil? && shadow.nil?

        {
          family_id: family.id,
          transaction_id: id,
          applied_provider: provider_key(categorization_provider),
          applied_category_name: applied&.category_name,
          shadow_provider: provider_key(@shadow_provider),
          shadow_category_name: shadow&.category_name,
          shadow_confidence: confidence_for(shadow),
          shadow_probabilities: (shadow.probabilities if shadow.respond_to?(:probabilities)) || {},
          # Both declining to guess counts as agreement — an abstention is an
          # answer. A provider returning no decision at all is not: the ids come
          # from the union of both lists, so one side can be missing entirely,
          # and comparing `nil == nil` would score that as agreement and inflate
          # the rate.
          agreed: applied.present? && shadow.present? && applied.category_name == shadow.category_name,
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      CategorizationComparison.insert_all(rows) if rows.any?
    rescue => error
      Rails.logger.warn("Recording shadow comparison failed for family #{family.id}: #{error.class}: #{error.message}")
    end

    def provider_key(provider)
      provider.class.name.demodulize.underscore
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
