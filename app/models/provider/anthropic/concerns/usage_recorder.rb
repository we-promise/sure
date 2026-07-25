module Provider::Anthropic::Concerns::UsageRecorder
  extend ActiveSupport::Concern

  private

    # Persists an LlmUsage row from an Anthropic Message#usage object.
    # Returns nil if no family is attached (e.g., system-initiated calls).
    def record_usage(model_name, raw_usage, operation:, metadata: {})
      # Attach token usage to the enclosing Sentry gen_ai span (if any) even
      # when no family is present — observability is independent of billing.
      if raw_usage
        span_usage = {
          "input_tokens" => raw_usage.input_tokens,
          "output_tokens" => raw_usage.output_tokens
        }
        if raw_usage.respond_to?(:cache_creation_input_tokens) && raw_usage.cache_creation_input_tokens
          span_usage["cache_creation_input_tokens"] = raw_usage.cache_creation_input_tokens
        end
        if raw_usage.respond_to?(:cache_read_input_tokens) && raw_usage.cache_read_input_tokens
          span_usage["cache_read_input_tokens"] = raw_usage.cache_read_input_tokens
        end
        LlmInstrumentation.add_current_span_usage(span_usage)
      end

      return unless family && raw_usage

      input_tokens = raw_usage.input_tokens.to_i
      output_tokens = raw_usage.output_tokens.to_i
      total_tokens = input_tokens + output_tokens
      cache_creation = raw_usage.respond_to?(:cache_creation_input_tokens) ? raw_usage.cache_creation_input_tokens : nil
      cache_read = raw_usage.respond_to?(:cache_read_input_tokens) ? raw_usage.cache_read_input_tokens : nil

      estimated_cost = LlmUsage.calculate_cost(
        model: model_name,
        prompt_tokens: input_tokens,
        completion_tokens: output_tokens,
        cache_creation_tokens: cache_creation,
        cache_read_tokens: cache_read
      )

      family.llm_usages.create!(
        provider: "anthropic",
        model: model_name,
        operation: operation,
        prompt_tokens: input_tokens,
        completion_tokens: output_tokens,
        total_tokens: total_tokens,
        cache_creation_tokens: cache_creation,
        cache_read_tokens: cache_read,
        estimated_cost: estimated_cost,
        metadata: metadata
      )

      Rails.logger.info("LLM usage recorded - Provider: anthropic, Operation: #{operation}, Cost: #{estimated_cost.inspect}")
    rescue => e
      Rails.logger.error("Failed to record LLM usage: #{e.message}")
    end

    def record_usage_error(model_name, operation:, error:, metadata: {})
      return unless family && error

      http_status_code = extract_http_status_code(error)

      family.llm_usages.create!(
        provider: "anthropic",
        model: model_name,
        operation: operation,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
        estimated_cost: nil,
        metadata: metadata.merge(error: safe_error_message(error), http_status_code: http_status_code)
      )
    rescue => e
      Rails.logger.error("Failed to record LLM usage error: #{e.message}")
    end

    def extract_http_status_code(error)
      if error.respond_to?(:status)
        error.status
      elsif error.respond_to?(:http_status)
        error.http_status
      elsif safe_error_message(error) =~ /(\d{3})/
        $1.to_i
      end
    end

    def safe_error_message(error)
      error&.message
    rescue => e
      "(message unavailable: #{e.class})"
    end
end
