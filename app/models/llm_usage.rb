class LlmUsage < ApplicationRecord
  belongs_to :family

  validates :provider, :model, :operation, presence: true
  validates :prompt_tokens, :completion_tokens, :total_tokens, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :estimated_cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :for_family, ->(family) { where(family: family) }
  scope :for_operation, ->(operation) { where(operation: operation) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_date_range, ->(start_date, end_date) { where(created_at: start_date..end_date) }

  # OpenAI pricing per 1M tokens (as of Oct 2025)
  # Source: https://platform.openai.com/docs/pricing
  PRICING = {
    "openai" => {
      # GPT-4.1 and similar models
      "gpt-4.1" => { prompt: 2.00, completion: 8.00 },
      "gpt-4.1-mini" => { prompt: 0.40, completion: 1.60 },
      "gpt-4.1-nano" => { prompt: 0.40, completion: 1.60 },
      # 4o
      "gpt-4o" => { prompt: 2.50, completion: 10.00 },
      "gpt-4o-mini" => { prompt: 0.15, completion: 0.60 },
      # GPT-5 models (estimated pricing)
      "gpt-5" => { prompt: 1.25, completion: 10.00 },
      "gpt-5-mini" => { prompt: 0.25, completion: 2.00 },
      "gpt-5-nano" => { prompt: 0.05, completion: 0.40 },
      "gpt-5-pro" => { prompt: 15.00, completion: 120.00 },
      # o1 models
      "o1-mini" => { prompt: 1.10, completion: 4.40 },
      "o1" => { prompt: 15.00, completion: 60.00 },
      # o3 models (estimated pricing)
      "o3" => { prompt: 2.00, completion: 8.00 },
      "o3-mini" => { prompt: 1.10, completion: 4.40 },
      "o3-pro" => { prompt: 20.00, completion: 80.00 }
    },
    "google" => {
      "gemini-2.5-pro" => { prompt: 1.25, completion: 10.00 },
      "gemini-2.5-flash" => { prompt: 0.3, completion: 2.50 }
    }
  }.freeze

  # Calculate cost for a model and token usage
  # Provider is automatically inferred from the model using the pricing map
  # Returns nil if pricing is not available for the model (e.g., custom/self-hosted providers)
  def self.calculate_cost(model:, prompt_tokens:, completion_tokens:)
    provider = infer_provider(model)
    pricing = find_pricing(provider, model)

    unless pricing
      Rails.logger.info("No pricing found for model: #{model} (inferred provider: #{provider})")
      return nil
    end

    # Pricing is per 1M tokens, so divide by 1_000_000
    prompt_cost = (prompt_tokens * pricing[:prompt]) / 1_000_000.0
    completion_cost = (completion_tokens * pricing[:completion]) / 1_000_000.0

    cost = (prompt_cost + completion_cost).round(6)
    Rails.logger.info("Calculated cost for #{provider}/#{model}: $#{cost} (#{prompt_tokens} prompt tokens, #{completion_tokens} completion tokens)")
    cost
  end

  # Find pricing for a model, with prefix matching support
  def self.find_pricing(provider, model)
    return nil unless PRICING.key?(provider)

    provider_pricing = PRICING[provider]

    # Try exact match first
    return provider_pricing[model] if provider_pricing.key?(model)

    # Try prefix matching (e.g., "gpt-4.1-2024-08-06" matches "gpt-4.1")
    provider_pricing.each do |model_prefix, pricing|
      return pricing if model.start_with?(model_prefix)
    end

    nil
  end

  # Infer provider from model name by checking which provider has pricing for it
  # Returns the provider name if found, or "openai" as default (for backward compatibility)
  def self.infer_provider(model)
    return "openai" if model.blank?

    # Check each provider to see if they have pricing for this model
    PRICING.each do |provider_name, provider_pricing|
      # Try exact match first
      return provider_name if provider_pricing.key?(model)

      # Try prefix matching
      provider_pricing.each_key do |model_prefix|
        return provider_name if model.start_with?(model_prefix)
      end
    end

    # Default to "openai" if no pricing found (for custom/self-hosted models)
    "openai"
  end

  # Aggregate statistics for a family
  def self.statistics_for_family(family, start_date: nil, end_date: nil)
    scope = for_family(family)
    scope = scope.for_date_range(start_date, end_date) if start_date && end_date

    # Exclude records with nil cost from cost calculations
    scope_with_cost = scope.where.not(estimated_cost: nil)

    requests_with_cost = scope_with_cost.count
    total_cost = scope_with_cost.sum(:estimated_cost).to_f.round(2)
    avg_cost = requests_with_cost > 0 ? (total_cost / requests_with_cost).round(4) : 0.0

    {
      total_requests: scope.count,
      requests_with_cost: requests_with_cost,
      total_prompt_tokens: scope.sum(:prompt_tokens),
      total_completion_tokens: scope.sum(:completion_tokens),
      total_tokens: scope.sum(:total_tokens),
      total_cost: total_cost,
      avg_cost: avg_cost,
      by_operation: scope_with_cost.group(:operation).sum(:estimated_cost).transform_values { |v| v.to_f.round(2) },
      by_model: scope_with_cost.group(:model).sum(:estimated_cost).transform_values { |v| v.to_f.round(2) }
    }
  end

  # Format cost as currency
  def formatted_cost
    estimated_cost.nil? ? "N/A" : "$#{estimated_cost.round(4)}"
  end

  # Estimate cost for auto-categorizing a batch of transactions
  # Based on typical token usage patterns:
  # - ~100 tokens per transaction in the prompt
  # - ~50 tokens per category
  # - ~50 tokens for completion per transaction
  # Returns nil if pricing is not available for the model
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
      completion_tokens: estimated_completion_tokens
    )
  end
end
