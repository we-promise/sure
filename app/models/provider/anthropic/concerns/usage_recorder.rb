module Provider::Anthropic::Concerns::UsageRecorder
  extend ActiveSupport::Concern

  private

    # Persists an LlmUsage row from an Anthropic Message#usage object.
    # Returns nil if no family is attached (e.g., system-initiated calls).
    def record_usage(model_name, raw_usage, operation:, metadata: {})
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

    # Anthropic::Errors::APIStatusError carries the parsed response body
    # directly on the error. The body can echo request content (potentially
    # sensitive, since these calls process user-uploaded financial documents),
    # so only allowlisted fields are extracted rather than forwarded whole.
    def safe_error_detail(error)
      body = error.respond_to?(:body) ? error.body : nil
      request_id = error.respond_to?(:headers) ? error.headers&.[]("request-id") : nil
      extract_error_detail(body, request_id)
    rescue => e
      "(detail unavailable: #{e.class})"
    end

    def extract_error_detail(body, request_id)
      body = body.with_indifferent_access if body.respond_to?(:with_indifferent_access)
      nested = body.is_a?(Hash) ? body[:error] : nil
      nested = nested.with_indifferent_access if nested.respond_to?(:with_indifferent_access)

      detail = {}
      detail[:type] = nested[:type] if nested.is_a?(Hash) && nested[:type].present?
      detail[:message] = nested[:message] if nested.is_a?(Hash) && nested[:message].present?
      detail[:request_id] = request_id if request_id.present?
      detail.presence
    end
end
