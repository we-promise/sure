# One llm_usages row per HTTP request, retries and failures included, from RubyLLM's
# `usage.ruby_llm`: the family is the usage owner and the call is the workflow Ai::CallContext
# opened. That event carries no error, so a failed row takes it from the `request.ruby_llm` event
# that finishes next, or else from the call's `.ai` event, which finishes last.
#
# Requests outside a call context with a family (health probes, eval runs) write nothing.
class Ai::Instrumentation::UsageSubscriber
  STATUSES = { succeeded: "succeeded", failed: "failed", cancelled: "cancelled" }.freeze

  def call(event)
    case event.name
    when "usage.ruby_llm" then record_request(event.payload)
    when "request.ruby_llm" then record_request_error(event.payload)
    else record_error(event.payload)
    end
  rescue StandardError => error
    Rails.logger.error("[Ai::Instrumentation::UsageSubscriber] #{error.class}: #{error.message}")
  end

  private
    def record_request(payload)
      family = payload[:owner]
      call = (payload[:workflow_metadata] || {}).to_h.stringify_keys
      return unless family.is_a?(Family) && call["call_id"].present?

      status = STATUSES.fetch(payload[:status], nil)
      return if status.nil?   # :pending entries finish later as another event

      tokens = Ai::Tokens.from_ruby_llm(payload[:tokens], payload[:cost])
      model = call["model"].presence || payload[:model].to_s

      family.llm_usages.create!(
        provider: call["endpoint"],
        model:,
        operation: call["feature"],
        status:,
        call_id: call["call_id"],
        prompt_tokens: tokens.prompt_tokens.to_i,
        completion_tokens: tokens.output_tokens.to_i,
        total_tokens: tokens.total_tokens.to_i,
        cache_read_tokens: tokens.cache_read_tokens,
        cache_creation_tokens: tokens.cache_write_tokens,
        estimated_cost: cost(tokens, model),
        metadata: {
          route: { endpoint: call["endpoint"], model: },
          tokens_unknown: (true unless tokens.known?)
        }.compact
      )
    end

    # The provider's reported cost first, otherwise the published prices. Unknown tokens have no
    # cost. LlmUsage prices cache reads and writes apart only for Anthropic; any other
    # provider's cached input is priced as input, as its own usage recorder does.
    def cost(tokens, model)
      return tokens.cost unless tokens.cost.nil?
      return unless tokens.known?

      prompt = LlmUsage.infer_provider(model) == "anthropic" ? tokens.input_tokens : tokens.prompt_tokens
      LlmUsage.calculate_cost(model:, prompt_tokens: prompt.to_i, completion_tokens: tokens.output_tokens.to_i,
                              cache_creation_tokens: tokens.cache_write_tokens.to_i, cache_read_tokens: tokens.cache_read_tokens.to_i)
    end

    # The request that just failed is the call's newest failed row without an error.
    def record_request_error(payload)
      call_id = (payload[:workflow_metadata] || {}).to_h.stringify_keys["call_id"]
      return if payload[:ai_error].blank? || call_id.blank?

      LlmUsage.where(id: unexplained_failures(call_id).order(created_at: :desc).limit(1).select(:id))
              .update_all([ "metadata = metadata || ?::jsonb", payload[:ai_error].to_json ])
    end

    def unexplained_failures(call_id) = LlmUsage.where(call_id:, status: "failed").where("NOT (metadata ? 'error')")

    def record_error(payload)
      return if payload[:error].blank? || payload[:call_id].blank? || payload[:family_id].blank?

      details = { error: payload[:error_message].presence || payload[:error], error_class: payload[:error],
                  http_status_code: payload[:http_status] }.compact
      unexplained_failures(payload[:call_id]).update_all([ "metadata = metadata || ?::jsonb", details.to_json ])
    end
end
