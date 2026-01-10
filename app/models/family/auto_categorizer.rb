class Family::AutoCategorizer
  Error = Class.new(StandardError)

  # Result struct that includes both the modified count and metadata about the LLM call
  Result = Data.define(:modified_count, :metadata) do
    def to_i
      modified_count
    end
  end

  def initialize(family, transaction_ids: [])
    @family = family
    @transaction_ids = transaction_ids
  end

  def auto_categorize
    raise Error, "No LLM provider for auto-categorization" unless llm_provider

    if scope.none?
      Rails.logger.info("No transactions to auto-categorize for family #{family.id}")
      return Result.new(modified_count: 0, metadata: { transactions_input: 0, transactions_categorized: 0 })
    else
      Rails.logger.info("Auto-categorizing #{scope.count} transactions for family #{family.id}")
    end

    categories_input = user_categories_input

    if categories_input.empty?
      Rails.logger.error("Cannot auto-categorize transactions for family #{family.id}: no categories available")
      return Result.new(modified_count: 0, metadata: { error: "no_categories_available" })
    end

    # Track timing for metadata
    start_time = Time.current

    result = llm_provider.auto_categorize(
      transactions: transactions_input,
      user_categories: categories_input,
      family: family
    )

    unless result.success?
      Rails.logger.error("Failed to auto-categorize transactions for family #{family.id}: #{result.error.message}")
      return Result.new(modified_count: 0, metadata: { error: result.error.message })
    end

    modified_count = 0
    categorized_count = 0
    scope.each do |transaction|
      auto_categorization = result.data.find { |c| c.transaction_id == transaction.id }

      category_id = categories_input.find { |c| c[:name] == auto_categorization&.category_name }&.dig(:id)

      if category_id.present?
        categorized_count += 1
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

    # Build metadata from the LLM usage record created during the call
    metadata = build_metadata(
      start_time: start_time,
      transactions_input: scope.count,
      transactions_categorized: categorized_count
    )

    Result.new(modified_count: modified_count, metadata: metadata)
  end

  private
    attr_reader :family, :transaction_ids

    # For now, OpenAI only, but this should work with any LLM concept provider
    def llm_provider
      Provider::Registry.get_provider(:openai)
    end

    # Build metadata hash from LLM usage and timing information
    def build_metadata(start_time:, transactions_input:, transactions_categorized:)
      duration_ms = ((Time.current - start_time) * 1000).round

      # Find the LLM usage record(s) created during the auto_categorize call
      llm_usages = family.llm_usages
                         .where("created_at >= ?", start_time)
                         .where(operation: "auto_categorize")
                         .order(created_at: :desc)

      # Sum up tokens from all LLM usage records (in case of retries)
      total_prompt_tokens = llm_usages.sum(:prompt_tokens)
      total_completion_tokens = llm_usages.sum(:completion_tokens)
      total_tokens = llm_usages.sum(:total_tokens)
      total_estimated_cost = llm_usages.sum(:estimated_cost)

      # Get model info from the most recent usage
      latest_usage = llm_usages.first

      {
        job_type: "auto_categorize",
        provider: latest_usage&.provider || "openai",
        model: latest_usage&.model,
        duration_ms: duration_ms,
        transactions_input: transactions_input,
        transactions_categorized: transactions_categorized,
        prompt_tokens: total_prompt_tokens,
        completion_tokens: total_completion_tokens,
        total_tokens: total_tokens,
        estimated_cost: total_estimated_cost&.to_f,
        llm_calls: llm_usages.count
      }.compact
    end

    def user_categories_input
      family.categories.map do |category|
        {
          id: category.id,
          name: category.name,
          is_subcategory: category.subcategory?,
          parent_id: category.parent_id,
          classification: category.classification
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

    def scope
      family.transactions.where(id: transaction_ids, category_id: nil)
                         .enrichable(:category_id)
                         .includes(:category, :merchant, :entry)
    end
end
