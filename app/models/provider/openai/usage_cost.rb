class Provider::Openai::UsageCost
  def self.calculate(model:, usage:, uri_base:)
    reported_cost = openrouter_cost(usage["cost"], uri_base)
    return reported_cost unless reported_cost.nil?

    LlmUsage.calculate_cost(
      model: model,
      prompt_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0
    )
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
