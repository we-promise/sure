# Fills in the category of a family's uncategorized transactions with AI, after rules and Bayes,
# and never over an answer that's locked. The requester of :categorize: Ai::GenerationJob runs it
# one batch at a time.
#
# Ai::Generations::CategorizeTransactions answers on an LLM, and its judgement
# (Ai::Judgements::CategorizeTransaction) on Jev, in one shape. Answers from a model with
# `calibrated_confidence` (cloud Jev) can be withheld by the family's threshold; the others
# always apply (section 6).
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

    log_jev_fallback
    generation
  end

  def apply_ai(result)
    decisions = result.value[:categorizations]
    shadow = run_shadow
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
      if withhold?(decision, result.route)
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
      source: self.class.name, family:, provider: result.route&.endpoint&.name,
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

  private
    attr_reader :family, :transaction_ids

    def generation
      Ai::Generations::CategorizeTransactions.new(transactions: transactions_input, categories: categories_input, family:)
    end

    # The instance chose Jev, but the config left it out because RubyLLM can't reach its endpoint.
    # Without this the only symptom is categorization silently running on the LLM. The endpoint is
    # redacted, because a gateway URL can carry a key.
    def log_jev_fallback
      return unless Ai::LegacyEnvConfig.categorization_provider == "jev" && Ai::LegacyEnvConfig::Jev.configured?

      endpoint = Ai::LegacyEnvConfig::Jev.effective_endpoint
      reason = Ai::LegacyEnvConfig::Jev.endpoint_allowed?(endpoint) ? Ai::LegacyEnvConfig::Jev.unsupported_reason(endpoint) : :path
      return unless reason

      DebugLogEntry.capture(
        category: "auto_categorization", level: "error", message: "Jev is misconfigured; falling back to the LLM provider",
        source: self.class.name, family:, provider: "jev",
        metadata: { endpoint: Ai::LegacyEnvConfig::Jev.redacted_endpoint(endpoint), reason:,
                    detail: Ai::LegacyEnvConfig::JEV_UNSUPPORTED.fetch(reason) }
      )
    end

    def log_no_categories
      Rails.logger.error("Cannot auto-categorize transactions for family #{family.id}: no categories available")
      DebugLogEntry.capture(
        category: "auto_categorization", level: "error", message: "AI categorization failed: no categories available",
        source: self.class.name, family:, metadata: { requested_transaction_ids: transaction_ids }
      )
    end

    # Only answers from a model with calibrated confidence can be gated (section 6), and one that
    # arrives without a confidence is malformed, so it's withheld: nil becomes 0, below any
    # positive threshold.
    def withhold?(decision, route)
      threshold = family.effective_categorization_confidence_threshold
      threshold.positive? && route&.model&.capable?(:calibrated_confidence) && decision[:confidence].to_f < threshold
    end

    # Asks the shadow_categorize route (the model not in use) to categorize the same batch, so it
    # can be judged on real data before anyone switches; its answers are never applied. Sampled
    # per run, and any failure is swallowed: a diagnostic must never break the categorization it
    # observes. Inline in the job until Ai::ShadowJob.
    def run_shadow
      rate = family.effective_categorization_shadow_rate
      return unless rate.positive? && rand < rate

      plan = Ai.plan(:shadow_categorize, family:)
      return unless plan

      result = generation.call(plan:)
      { decisions: result.value[:categorizations], provider: result.route.endpoint.name } if result.success?
    rescue => error
      Rails.logger.warn("Shadow categorization failed for family #{family.id}: #{error.class}: #{error.message}")
      nil
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
          applied_provider: primary_route&.endpoint&.name,
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
