class Provider::Openai::UsageCost
  def self.calculate(model:, usage:, uri_base:)
    reported_cost = openrouter_cost(usage["cost"], uri_base)
    return reported_cost unless reported_cost.nil?

    prompt_tokens = usage["prompt_tokens"] || usage["input_tokens"] || 0
    cache_read_tokens = anthropic_cache_read_tokens(model, usage)

    LlmUsage.calculate_cost(
      model: model,
      prompt_tokens: [ prompt_tokens - cache_read_tokens, 0 ].max,
      completion_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
      cache_read_tokens: cache_read_tokens
    )
  end

  # OpenAI-compatible usage counts cached input inside prompt_tokens. Claude
  # bills it at its own cache-read rate, so split it out for Anthropic models.
  private_class_method def self.anthropic_cache_read_tokens(model, usage)
    return 0 unless LlmUsage.infer_provider(model) == "anthropic"

    details = usage["prompt_tokens_details"] || usage["input_tokens_details"]
    details.is_a?(Hash) ? details["cached_tokens"].to_i : 0
  end

  private_class_method def self.openrouter_cost(value, uri_base)
    # OpenAI-compatible APIs do not share a currency contract for usage.cost.
    # Only OpenRouter's official API reports the account charge in USD credits.
    uri = URI.parse(uri_base.to_s)
    return unless uri.scheme == "https" && uri.port == 443 &&
      %w[openrouter.ai eu.openrouter.ai us.openrouter.ai].include?(uri.host&.downcase) &&
      %w[/api/v1 /api/v1/].include?(uri.path)
    return unless value.is_a?(Numeric)

    cost = BigDecimal(value.to_s, exception: false)
    cost if cost&.finite? && cost >= 0
  rescue URI::InvalidURIError
    nil
  end
end
