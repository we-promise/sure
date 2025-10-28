module Provider::Openai::Concerns::UsageRecorder
  extend ActiveSupport::Concern

  private

    # Records LLM usage for a family
    # Handles both old (prompt_tokens/completion_tokens) and new (input_tokens/output_tokens) API formats
    # Automatically infers provider from model name
    # Returns nil if pricing is unavailable (e.g., custom/self-hosted models)
    def record_usage(model_name, usage_data, operation:, metadata: {})
      return unless family && usage_data

      # Handle both old and new OpenAI API response formats
      # Old format: prompt_tokens, completion_tokens, total_tokens
      # New format: input_tokens, output_tokens, total_tokens
      prompt_tokens = usage_data["prompt_tokens"] || usage_data["input_tokens"] || 0
      completion_tokens = usage_data["completion_tokens"] || usage_data["output_tokens"] || 0
      total_tokens = usage_data["total_tokens"] || 0

      estimated_cost = LlmUsage.calculate_cost(
        model: model_name,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens
      )

      # Log when we can't estimate the cost (e.g., custom/self-hosted models)
      if estimated_cost.nil?
        Rails.logger.info("Recording LLM usage without cost estimate for unknown model: #{model_name} (custom provider: #{custom_provider})")
      end

      inferred_provider = LlmUsage.infer_provider(model_name)
      family.llm_usages.create!(
        provider: inferred_provider,
        model: model_name,
        operation: operation,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        estimated_cost: estimated_cost,
        metadata: metadata
      )

      Rails.logger.info("LLM usage recorded - Operation: #{operation}, Cost: #{estimated_cost.inspect}")
    rescue => e
      Rails.logger.error("Failed to record LLM usage: #{e.message}")
    end
end
