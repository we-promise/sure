# One llm_usages row per request (section 10). RubyLLM publishes `usage.ruby_llm` for every
# HTTP attempt, retries and failures included, in the caller's process, so this reads the
# family from the usage owner and the call from the workflow Ai::CallContext opened:
# `workflow_id` is the call id, and `workflow_metadata` names the feature and route.
#
# A failed request's usage event carries no error, so the call's `.ai` event, which finishes
# afterwards, adds the error class and message to the call's failed rows.
#
# Requests outside a call context with a family (health probes, eval runs) write nothing.
class Ai::Instrumentation::UsageSubscriber
  STATUSES = { succeeded: "succeeded", failed: "failed", cancelled: "cancelled" }.freeze

  def call(event)
    event.name == "usage.ruby_llm" ? record_request(event.payload) : record_error(event.payload)
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
          correlation_id: call["correlation_id"],
          shadow: (true if call["shadow"] == "true"),
          tokens_unknown: (true unless tokens.known?)
        }.compact
      )
    end

    # The provider's reported cost first, otherwise the published prices (until presets carry
    # each model's own prices, PR 7). Unknown tokens have no cost.
    def cost(tokens, model)
      return tokens.cost unless tokens.cost.nil?
      return unless tokens.known?

      LlmUsage.calculate_cost(model:, prompt_tokens: tokens.input_tokens.to_i, completion_tokens: tokens.output_tokens.to_i,
                              cache_creation_tokens: tokens.cache_write_tokens.to_i, cache_read_tokens: tokens.cache_read_tokens.to_i)
    end

    def record_error(payload)
      return if payload[:error].blank? || payload[:call_id].blank? || payload[:family_id].blank?

      details = { error: payload[:error_message].presence || payload[:error], error_class: payload[:error],
                  http_status_code: payload[:http_status] }.compact
      LlmUsage.where(call_id: payload[:call_id], status: "failed")
              .where("NOT (metadata ? 'error')")
              .update_all([ "metadata = metadata || ?::jsonb", details.to_json ])
    end
end
