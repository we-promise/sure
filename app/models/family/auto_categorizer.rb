# Fills in the category of a family's uncategorized transactions with AI, after rules and Bayes,
# and never over an answer that's locked. The requester of :categorize: Ai::GenerationJob runs it
# one batch at a time.
#
# The route's first entry decides who answers: an LLM through
# Ai::Generations::CategorizeTransactions, or Jev through Provider::Jev (JevCall). Jev's answers carry calibrated confidence, so the family's threshold can
# withhold them; the LLMs' don't, so they always apply.
class Family::AutoCategorizer
  include Ai::Requester
  ai_feature :categorize

  def self.from_ai_job(ids:, family_id:, rule_run_id: nil)
    new(Family.find(family_id), transaction_ids: ids, rule_run: (RuleRun.find_by(id: rule_run_id) if rule_run_id))
  end

  def initialize(family, transaction_ids: [], rule_run: nil)
    @family = family
    @transaction_ids = transaction_ids
    @rule_run = rule_run
  end

  def ai_generation
    @cached_ids = cached_transaction_ids
    @blocked_ids = protected_transaction_ids - @cached_ids
    log_cache_usage(@cached_ids) if @cached_ids.any?
    log_blocked_transactions(@blocked_ids) if @blocked_ids.any?

    if scope.none?
      Rails.logger.info("No transactions to auto-categorize for family #{family.id}")
      return
    end
    Rails.logger.info("Auto-categorizing #{scope.count} transactions for family #{family.id}")

    if categories_input.empty?
      log_no_categories
      return
    end

    plan = Ai.plan(:categorize, family:)
    return JevCall.new(self, plan.route) if plan&.route&.judge?

    log_jev_fallback if family.effective_categorization_provider == "jev"

    Ai::Generations::CategorizeTransactions.new(transactions: transactions_input, categories: categories_input, family:)
  end

  def apply_ai(result)
    decisions = result.value[:categorizations]
    shadow = run_shadow(result.route)
    modified_count = 0
    categorized_transaction_ids = []
    withheld = []

    scope.each do |transaction|
      decision = decisions.find { _1[:transaction_id] == transaction.id }
      category_id = categories_input.find { |c| c[:name] == decision&.dig(:category_name) }&.dig(:id)
      next if category_id.blank?

      # Withheld rather than applied: the transaction is left unlocked and still enrichable, so a
      # later run (or a better model) can try again. Applying a coin-flip guess and locking it
      # would be worse than leaving it blank, because the lock stops anything else correcting it.
      if withhold?(decision)
        withheld << { transaction_id: transaction.id, category_name: decision[:category_name], confidence: decision[:confidence] }
        next
      end

      categorized_transaction_ids << transaction.id
      was_modified = transaction.enrich_attribute(:category_id, category_id, source: "ai")
      transaction.lock_attr!(:category_id)
      modified_count += 1 if was_modified
    end

    record_shadow_comparisons(result.route, decisions, shadow) if shadow

    DebugLogEntry.capture(
      category: "auto_categorization", level: "info", message: "AI categorization completed",
      source: self.class.name, family:, provider: provider_key(result.route),
      metadata: {
        requested_transaction_ids: transaction_ids,
        categorized_transaction_ids:,
        cached_transaction_ids: @cached_ids,
        blocked_transaction_ids: @blocked_ids,
        modified_count:,
        confidence_threshold: family.effective_categorization_confidence_threshold,
        withheld_low_confidence: withheld,
        shadow_compared_count: shadow ? shadow[:decisions].size : 0
      }.compact
    )

    modified_count
  end

  def ai_finished(count) = @rule_run&.complete_job!(modified_count: count)

  def ai_failed(error)
    @rule_run&.fail_job!(error:, source: self.class.name, transaction_ids:)
    DebugLogEntry.capture(
      category: "auto_categorization", level: "error", message: "AI categorization failed",
      source: self.class.name, family:,
      metadata: { error_class: error.class.name, error_message: error.message.truncate(500), requested_transaction_ids: transaction_ids }
    )
  end

  def ai_correlation_id = @rule_run ? "rule_run:#{@rule_run.id}" : nil

  # Jev's decisions as the generation's hashes, or nil when Jev failed.
  def jev_decisions(provider = jev_provider)
    return unless provider

    response = provider.auto_categorize(transactions: transactions_input, user_categories: categories_input, family:)
    return unless response.success?

    response.data.map do |decision|
      { transaction_id: decision.transaction_id, category_name: decision.category_name,
        confidence: (decision.confidence if decision.respond_to?(:confidence)),
        probabilities: (decision.probabilities if decision.respond_to?(:probabilities)), calibrated: true }
    end
  end

  # Jev: one Provider::Jev call per batch, answered in the generation's shape, with
  # each answer's calibrated confidence. No failover from Jev, as today.
  class JevCall
    def initialize(categorizer, route)
      @categorizer, @route = categorizer, route
    end

    def call(**)
      response = @categorizer.jev_decisions
      return Ai::Result.new(value: { categorizations: response }, route: @route) if response

      Ai::Result.failure(Ai::Error::Upstream.new("Jev categorization failed"), route: @route)
    end
  end

  private
    attr_reader :family, :transaction_ids

    def jev_provider
      Provider::Registry.get_provider(:jev)
    rescue Provider::Error => error
      log_jev_misconfiguration(error, "skipping Jev")
      nil
    end

    def log_jev_misconfiguration(error, consequence)
      # Without this the only symptom is categorization silently running on the provider the
      # family did not choose. The endpoint is redacted because a gateway URL can carry a key.
      DebugLogEntry.capture(
        category: "auto_categorization", level: "error", message: "Jev is misconfigured; #{consequence}",
        source: self.class.name, family:, provider: "jev",
        metadata: {
          endpoint: Provider::Jev.redacted_endpoint(Provider::Jev.effective_endpoint),
          error_class: error.class.name,
          error_message: error.message
        }
      )
    end

    # The family chose Jev but its route has none: say why, as today, when Jev can't be built.
    def log_jev_fallback
      Provider::Registry.get_provider(:jev)
    rescue Provider::Error => error
      log_jev_misconfiguration(error, "falling back to the LLM provider")
    end

    def log_no_categories
      Rails.logger.error("Cannot auto-categorize transactions for family #{family.id}: no categories available")
      DebugLogEntry.capture(
        category: "auto_categorization", level: "error", message: "AI categorization failed: no categories available",
        source: self.class.name, family:, metadata: { requested_transaction_ids: transaction_ids }
      )
    end

    # Only answers with calibrated confidence (Jev's) can be gated, and one that arrives without a
    # confidence is malformed, so it's withheld: nil becomes 0, below any positive threshold.
    def withhold?(decision)
      threshold = family.effective_categorization_confidence_threshold
      threshold.positive? && decision[:calibrated] && decision[:confidence].to_f < threshold
    end

    # Asks the provider that is NOT in use to categorize the same batch, so it can be judged on
    # real data before anyone switches; its answers are never applied. Sampled per run, and any
    # failure is swallowed: a diagnostic must never break the categorization it observes. It runs
    # inline, in the categorization job.
    def run_shadow(primary_route)
      rate = family.effective_categorization_shadow_rate
      return unless rate.positive? && rand < rate

      decisions, route_key =
        if primary_route&.judge?
          shadow_on_llm
        elsif (provider = shadow_jev_provider)
          [ jev_decisions(provider), "jev" ]
        end
      decisions && { decisions:, provider: route_key }
    rescue => error
      Rails.logger.warn("Shadow categorization failed for family #{family.id}: #{error.class}: #{error.message}")
      nil
    end

    # A Jev family's shadow: the LLM entries of its categorize route.
    def shadow_on_llm
      plan = Ai.plan(:categorize, family:)
      llm = plan&.routes&.reject(&:judge?)
      return if llm.blank?

      result = Ai::Generations::CategorizeTransactions.new(transactions: transactions_input, categories: categories_input, family:)
                                                       .call(plan: plan.with(routes: llm))
      [ result.value[:categorizations], provider_key(result.route) ] if result.success?
    end

    # An LLM family's shadow is Jev, when it can be built, as today's shadow_categorization_provider.
    def shadow_jev_provider
      family.shadow_categorization_provider { |error| log_jev_misconfiguration(error, "skipping the shadow comparison") }
            .then { _1.is_a?(Provider::Jev) ? _1 : nil }
    end

    # Built from the decision lists rather than from `scope`, which is a fresh query: by now the
    # applied answers have been written and locked, so re-running it would match nothing.
    def record_shadow_comparisons(primary_route, applied_decisions, shadow)
      shadow_decisions = shadow[:decisions]
      ids = (applied_decisions.map { _1[:transaction_id] } + shadow_decisions.map { _1[:transaction_id] }).uniq

      rows = ids.filter_map do |id|
        applied = applied_decisions.find { _1[:transaction_id] == id }
        shadowed = shadow_decisions.find { _1[:transaction_id] == id }
        next if applied.nil? && shadowed.nil?

        {
          family_id: family.id,
          transaction_id: id,
          applied_provider: provider_key(primary_route),
          applied_category_name: applied&.dig(:category_name),
          shadow_provider: shadow[:provider],
          shadow_category_name: shadowed&.dig(:category_name),
          shadow_confidence: shadowed&.dig(:confidence),
          shadow_probabilities: shadowed&.dig(:probabilities) || {},
          # Both declining to guess counts as agreement — an abstention is an answer. A missing
          # decision is not: comparing nil == nil would inflate the rate.
          agreed: applied.present? && shadowed.present? && applied[:category_name] == shadowed[:category_name],
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      CategorizationComparison.insert_all(rows) if rows.any?
    rescue => error
      Rails.logger.warn("Recording shadow comparison failed for family #{family.id}: #{error.class}: #{error.message}")
    end

    # The provider names CategorizationComparison and the debug log have always used.
    def provider_key(route)
      return if route.nil?
      return "jev" if route.judge?

      route.endpoint.protocol == :anthropic ? "anthropic" : "openai"
    end

    def categories_input
      @categories_input ||= family.categories.map do |category|
        { id: category.id, name: category.name, is_subcategory: category.subcategory?, parent_id: category.parent_id }
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

    def protected_transaction_ids = protected_transactions.pluck(:id)

    def protected_transactions
      family.transactions
            .where(id: transaction_ids)
            .where(Arel.sql("transactions.locked_attributes ? :attribute"), attribute: "category_id")
    end

    def log_cache_usage(cached_transaction_ids)
      DebugLogEntry.capture(
        category: "auto_categorization", level: "info", message: "AI categorization cache used",
        source: self.class.name, family:, metadata: { cached_transaction_ids: }
      )
    end

    def log_blocked_transactions(blocked_transaction_ids)
      DebugLogEntry.capture(
        category: "auto_categorization", level: "info", message: "AI categorization blocked by enrichment protection",
        source: self.class.name, family:, metadata: { blocked_transaction_ids: }
      )
    end

    def scope
      family.transactions.where(id: transaction_ids, category_id: nil)
                         .enrichable(:category_id)
                         .includes(:category, :merchant, :entry)
    end
end
