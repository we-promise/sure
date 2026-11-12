class LlmUsage < ApplicationRecord
  belongs_to :family

  validates :provider, :model, :operation, presence: true
  validates :prompt_tokens, :completion_tokens, :total_tokens, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :estimated_cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # One row per request; a call's requests share a call_id. Rows from before
  # call_id existed, and rows the per-provider usage recorders still write, have none: each is a
  # call of one request.
  CALL_KEY = "COALESCE(llm_usages.call_id, llm_usages.id)".freeze

  enum :status, { succeeded: "succeeded", failed: "failed", cancelled: "cancelled" }, validate: true

  # The per-provider usage recorders mark a failed request by its error in metadata, under a
  # symbol key until the row is saved and read back.
  before_validation -> { self.status = "failed" }, if: -> { succeeded? && metadata.is_a?(Hash) && metadata.with_indifferent_access[:error].present? }

  scope :for_family, ->(family) { where(family: family) }
  scope :for_operation, ->(operation) { where(operation: operation) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_date_range, ->(start_date, end_date) { where(created_at: start_date..end_date) }

  # Standard USD pricing per 1M tokens by provider and model, refreshed by
  # bin/update_llm_pricing. Sources and estimation limits: docs/hosting/ai.md#cost-considerations
  pricing_config = YAML.load_file(Rails.root.join("config/llm_pricing.yml"), permitted_classes: [ Date ], aliases: true)

  # Last complete review of every listed model, not a provider price-change date.
  PRICING_VERIFIED_ON = pricing_config.fetch("verified_on").freeze

  PRICING = pricing_config.fetch("providers").transform_values do |models|
    models.transform_values { |pricing| pricing.deep_symbolize_keys.freeze }.freeze
  end.freeze

  # Calculate cost for a model and token usage
  # Provider is automatically inferred from the model using the pricing map
  # Returns nil if pricing is not available for the model (e.g., custom/self-hosted providers)
  # @param apply_long_context_pricing [Boolean] use per-request tiers; disable for aggregate batch estimates
  # @return [Float, nil] estimated USD cost
  def self.calculate_cost(model:, prompt_tokens:, completion_tokens:, cache_creation_tokens: 0, cache_read_tokens: 0,
                          apply_long_context_pricing: true)
    provider = infer_provider(model)
    pricing = find_pricing(provider, model)

    unless pricing
      Rails.logger.info("No pricing found for model: #{model} (inferred provider: #{provider})")
      return nil
    end

    # Anthropic reports cached input apart from input_tokens, but its
    # long-context tier counts cache reads and writes in the prompt length.
    cached_input_tokens = provider == "anthropic" ? cache_creation_tokens.to_i + cache_read_tokens.to_i : 0
    long_context = pricing[:long_context]
    if apply_long_context_pricing && long_context && prompt_tokens + cached_input_tokens > long_context[:threshold]
      pricing = long_context
    end

    # Pricing is per 1M tokens, so divide by 1_000_000
    prompt_cost = (prompt_tokens * pricing[:prompt]) / 1_000_000.0
    completion_cost = (completion_tokens * pricing[:completion]) / 1_000_000.0

    # Anthropic prompt-cache tokens bill relative to the input rate: cache
    # writes at 1.25x, cache reads at 0.1x unless the model lists its own
    # cache_read rate. These multipliers are Anthropic's;
    # gate on the provider so a non-Anthropic caller that happens to pass cache
    # counts can't be priced with the wrong rates (OpenAI cache rates vary by
    # model). Without cache pricing at all, estimated_cost
    # under-reports every cached Anthropic call vs the real bill (see #1984 review).
    cache_creation_cost = 0.0
    cache_read_cost = 0.0
    if provider == "anthropic"
      cache_creation_cost = (cache_creation_tokens.to_i * pricing[:prompt] * 1.25) / 1_000_000.0
      cache_read_cost = (cache_read_tokens.to_i * (pricing[:cache_read] || pricing[:prompt] * 0.10)) / 1_000_000.0
    end

    cost = (prompt_cost + completion_cost + cache_creation_cost + cache_read_cost).round(6)
    Rails.logger.info("Calculated cost for #{provider}/#{model}: $#{cost} (#{prompt_tokens} prompt + #{cache_creation_tokens.to_i} cache-write + #{cache_read_tokens.to_i} cache-read input, #{completion_tokens} completion)")
    cost
  end

  # Find pricing for a model, with prefix matching support
  def self.find_pricing(provider, model)
    return nil unless PRICING.key?(provider)

    model = model.delete_prefix("#{provider}/")

    provider_pricing = PRICING[provider]

    # Claude: the exact version row (ignoring snapshot dates and suffixes), else
    # the family row, so "claude-opus-5-6" doesn't take the "claude-opus-5" rate.
    # OpenRouter writes versions with dots ("claude-opus-4.6").
    if provider == "anthropic"
      family, version = model.tr(".", "-").match(/\A(claude-[a-z]+)((?:-\d{1,2}(?!\d))*)/)&.captures
      # "-4-0" aliases ("claude-opus-4-0") name the "-4" rows.
      return family && (provider_pricing["#{family}#{version.delete_suffix("-0")}"] || provider_pricing[family])
    end

    # Try exact match first
    return provider_pricing[model] if provider_pricing.key?(model)

    # Try prefix matching longest-first so snapshot IDs for variants (e.g.,
    # "gpt-5.4-mini-2026-03-17") do not match a broader family row
    # ("gpt-5.4") before their specific pricing row. A row covers its snapshots
    # but not later versions: "gpt-5" must not price "gpt-5.7-sol".
    provider_pricing.sort_by { |model_prefix, _pricing| -model_prefix.length }.each do |model_prefix, pricing|
      return pricing if model.start_with?(model_prefix) && !model.delete_prefix(model_prefix).match?(/\A\.?\d/)
    end

    tier = model[/\Agpt-[\d.]+-(astra|sol|terra|luna)\b/, 1]
    tier && provider_pricing["gpt-#{tier}"]
  end

  # Infer provider from model name by checking which provider has pricing for it
  # Returns the provider name if found, or "openai" as default (for backward compatibility)
  def self.infer_provider(model)
    return "openai" if model.blank?

    # Bedrock + Vertex prefix model IDs with "anthropic." regardless of
    # whether the Claude family is in the local PRICING map. Attribute them
    # to the Anthropic provider so cost-ledger filtering by provider is
    # correct even when we can't compute a per-token rate (custom endpoints
    # bill via their own provider, not Anthropic directly).
    return "anthropic" if model.start_with?("anthropic.", "anthropic/")
    return "google" if model.start_with?("gemini-", "google/")

    # Check each provider to see if they have pricing for this model
    PRICING.each do |provider_name, provider_pricing|
      # Try exact match first
      return provider_name if provider_pricing.key?(model)

      # Try prefix matching longest-first to mirror find_pricing.
      provider_pricing.keys.sort_by { |model_prefix| -model_prefix.length }.each do |model_prefix|
        return provider_name if model.start_with?(model_prefix)
      end
    end

    # Default to "openai" if no pricing found (for custom/self-hosted models)
    "openai"
  end

  # Aggregate statistics for a family, counting calls rather than requests: a call RubyLLM or
  # the transport retried is still one call.
  def self.statistics_for_family(family, start_date: nil, end_date: nil)
    scope = for_family(family)
    scope = scope.for_date_range(start_date, end_date) if start_date && end_date

    # Exclude records with nil cost from cost calculations
    scope_with_cost = scope.where.not(estimated_cost: nil)

    calls_with_cost = scope_with_cost.distinct.count(Arel.sql(CALL_KEY))
    cost = scope_with_cost.sum(:estimated_cost).to_f
    total_cost = cost.round(2)
    avg_cost = calls_with_cost > 0 ? (cost / calls_with_cost).round(4) : 0.0   # from the unrounded total

    {
      total_calls: scope.distinct.count(Arel.sql(CALL_KEY)),
      total_requests: scope.count,
      calls_with_cost: calls_with_cost,
      total_prompt_tokens: scope.sum(:prompt_tokens),
      total_completion_tokens: scope.sum(:completion_tokens),
      total_tokens: scope.sum(:total_tokens),
      total_cost: total_cost,
      avg_cost: avg_cost,
      by_operation: scope_with_cost.group(:operation).sum(:estimated_cost).transform_values { |v| v.to_f.round(2) },
      by_model: scope_with_cost.group(:model).sum(:estimated_cost).transform_values { |v| v.to_f.round(2) }
    }
  end

  # The most recent calls in scope, newest first, each with all its requests in order, even one
  # outside the date range (a retry just after midnight).
  # @return [Array<LlmUsage::Call>]
  def self.recent_calls(limit: 100)
    keys = group(Arel.sql(CALL_KEY)).order(Arel.sql("MAX(llm_usages.created_at) DESC")).limit(limit).pluck(Arel.sql(CALL_KEY))
    history = unscope(where: :created_at)
    requests = history.where(id: keys).or(history.where(call_id: keys)).order(:created_at).group_by { _1.call_id || _1.id }

    keys.filter_map { requests[_1] }.map { LlmUsage::Call.new(_1) }
  end

  # Format cost as currency
  def formatted_cost
    estimated_cost.nil? ? "N/A" : "$#{estimated_cost.round(4)}"
  end

  # Get the HTTP status code from metadata
  def http_status_code
    metadata&.dig("http_status_code")
  end

  # Get the error message from metadata
  def error_message
    metadata&.dig("error")
  end

  # Estimate cost for auto-categorizing a batch of transactions
  # Based on typical token usage patterns:
  # - ~100 tokens per transaction in the prompt
  # - ~50 tokens per category
  # - ~50 tokens for completion per transaction
  # Returns nil if pricing is not available for the model
  # Aggregate estimates assume short requests produced by the batch slicer.
  # @return [Float, nil] approximate total USD cost across categorization requests
  def self.estimate_auto_categorize_cost(transaction_count:, category_count:, model: "gpt-4.1")
    return 0.0 if transaction_count.zero?

    # Estimate tokens
    base_prompt_tokens = 150 # System message and instructions
    transaction_tokens = transaction_count * 100
    category_tokens = category_count * 50
    estimated_prompt_tokens = base_prompt_tokens + transaction_tokens + category_tokens

    # Completion tokens: roughly one category name per transaction
    estimated_completion_tokens = transaction_count * 50

    # calculate_cost will automatically infer the provider from the model
    # Returns nil if pricing is not available
    calculate_cost(
      model: model,
      prompt_tokens: estimated_prompt_tokens,
      completion_tokens: estimated_completion_tokens,
      apply_long_context_pricing: false
    )
  end
end
