# Emits Sentry AI Agent Monitoring spans (`gen_ai.*`) around LLM calls, agent
# runs, and tool executions, following the Sentry gen_ai span conventions:
# https://getsentry.github.io/sentry-conventions/attributes/gen_ai/
#
# Every helper is a safe no-op when Sentry is not initialized or there is no
# active transaction, so callers never need to guard for Sentry themselves.
#
# Privacy: prompts, completions, and tool payloads are user content and are
# only attached when `send_default_pii` is enabled in the Sentry config
# (opt-in via SENTRY_SEND_DEFAULT_PII=true). Model names, token counts,
# latency, and error status are always recorded — they contain no user data.
module LlmInstrumentation
  extend self

  AGENT_NAME = "sure_assistant"

  # Caps JSON-stringified message/tool payloads so a large prompt can't blow
  # past Sentry's event size limits and drop the whole transaction.
  MAX_CONTENT_LENGTH = 20_000

  # Wraps a single LLM call in a `gen_ai.{operation}` span (e.g. `gen_ai.chat`,
  # `gen_ai.auto_categorize`). Yields the span (or nil when tracing is off) so
  # callers can attach usage/output attributes once the response is known.
  def with_gen_ai_span(operation:, model:, system: nil, conversation_id: nil, &block)
    with_span(
      op: "gen_ai.#{operation}",
      description: "#{operation} #{model}",
      attributes: {
        "gen_ai.operation.name" => operation,
        "gen_ai.request.model" => model,
        "gen_ai.system" => system,
        "gen_ai.conversation.id" => conversation_id
      },
      &block
    )
  end

  # Wraps a full assistant turn (LLM calls + tool executions) in a
  # `gen_ai.invoke_agent` span. Also attributes the run to a pseudonymous user
  # so Sentry's Conversations view can populate its User column.
  def with_agent_span(agent_name: AGENT_NAME, model: nil, conversation_id: nil, user_identifier: nil, &block)
    set_scope_user(user_identifier)

    with_span(
      op: "gen_ai.invoke_agent",
      description: "invoke_agent #{agent_name}",
      attributes: {
        "gen_ai.operation.name" => "invoke_agent",
        "gen_ai.agent.name" => agent_name,
        "gen_ai.request.model" => model,
        "gen_ai.conversation.id" => conversation_id
      },
      &block
    )
  end

  # Wraps an assistant function/tool call in a `gen_ai.execute_tool` span.
  def with_tool_span(tool_name:, tool_description: nil, agent_name: AGENT_NAME, &block)
    with_span(
      op: "gen_ai.execute_tool",
      description: "execute_tool #{tool_name}",
      attributes: {
        "gen_ai.operation.name" => "execute_tool",
        "gen_ai.tool.name" => tool_name,
        "gen_ai.tool.description" => tool_description,
        "gen_ai.agent.name" => agent_name
      },
      &block
    )
  end

  # Adds token usage to a gen_ai span, accumulating across multiple calls so
  # batched one-shot operations (e.g. auto-categorize over several slices) sum
  # correctly. Accepts both OpenAI shapes (prompt_tokens/completion_tokens and
  # input_tokens/output_tokens with *_tokens_details) and the Anthropic shape
  # (cache_read_input_tokens/cache_creation_input_tokens reported separately).
  #
  # Sentry expects totals to INCLUDE the cached/reasoning subsets — reporting a
  # cached count larger than the input total produces negative costs — so
  # Anthropic's separately-reported cache tokens are folded into the total.
  def add_span_usage(span, usage)
    return unless span && usage.present?

    usage = usage.to_h.deep_stringify_keys
    return if usage.empty?

    input_tokens = (usage["input_tokens"] || usage["prompt_tokens"]).to_i
    output_tokens = (usage["output_tokens"] || usage["completion_tokens"]).to_i

    cached_tokens = usage.dig("input_tokens_details", "cached_tokens") ||
      usage.dig("prompt_tokens_details", "cached_tokens") ||
      usage["cache_read_input_tokens"]
    cache_write_tokens = usage["cache_creation_input_tokens"]
    reasoning_tokens = usage.dig("output_tokens_details", "reasoning_tokens") ||
      usage.dig("completion_tokens_details", "reasoning_tokens")

    # Anthropic reports cache reads/writes outside input_tokens; fold them in
    # so the total includes its subsets, per the Sentry cost model.
    if usage.key?("cache_read_input_tokens") || usage.key?("cache_creation_input_tokens")
      input_tokens += usage["cache_read_input_tokens"].to_i + usage["cache_creation_input_tokens"].to_i
    end

    increment_span_data(span, "gen_ai.usage.input_tokens", input_tokens)
    increment_span_data(span, "gen_ai.usage.output_tokens", output_tokens)
    increment_span_data(span, "gen_ai.usage.total_tokens", input_tokens + output_tokens)
    increment_span_data(span, "gen_ai.usage.input_tokens.cached", cached_tokens.to_i) if cached_tokens
    increment_span_data(span, "gen_ai.usage.input_tokens.cache_write", cache_write_tokens.to_i) if cache_write_tokens
    increment_span_data(span, "gen_ai.usage.output_tokens.reasoning", reasoning_tokens.to_i) if reasoning_tokens
  rescue => e
    log_instrumentation_failure(__method__, e)
  end

  # Adds usage to the innermost active gen_ai span, if any. Hook point for the
  # provider UsageRecorder concerns, which know token counts deep inside
  # one-shot operations where the span object is not in scope.
  def add_current_span_usage(usage)
    return unless sentry_active?

    span = Sentry.get_current_scope&.get_span
    return unless span && span.op.to_s.start_with?("gen_ai.")

    add_span_usage(span, usage)
  rescue => e
    log_instrumentation_failure(__method__, e)
  end

  # Attaches the request content (PII — opt-in only, see module docs).
  # `messages` may be a raw prompt string or an array of {role:, content:}
  # hashes in the OpenAI wire shape.
  def set_span_input(span, messages, instructions: nil)
    return unless span && capture_content?

    formatted = format_messages(messages)
    span.set_data("gen_ai.input.messages", truncate_content(JSON.generate(formatted))) if formatted.any?

    instructions_text = format_instructions(instructions)
    span.set_data("gen_ai.system_instructions", truncate_content(instructions_text)) if instructions_text.present?
  rescue => e
    log_instrumentation_failure(__method__, e)
  end

  # Attaches the response text (PII — opt-in only, see module docs).
  def set_span_output(span, text)
    return unless span && capture_content? && text.present?

    output = [ { role: "assistant", parts: [ { type: "text", content: text } ] } ]
    span.set_data("gen_ai.output.messages", truncate_content(JSON.generate(output)))
  rescue => e
    log_instrumentation_failure(__method__, e)
  end

  # Attaches tool call arguments/result (PII — opt-in only, see module docs).
  def set_span_tool_call(span, arguments: nil, result: nil)
    return unless span && capture_content?

    span.set_data("gen_ai.tool.call.arguments", truncate_content(JSON.generate(arguments))) unless arguments.nil?
    span.set_data("gen_ai.tool.call.result", truncate_content(JSON.generate(result))) unless result.nil?
  rescue => e
    log_instrumentation_failure(__method__, e)
  end

  def capture_content?
    sentry_active? && Sentry.configuration&.send_default_pii
  end

  private

    def with_span(op:, description:, attributes: {})
      return yield(nil) unless sentry_active?

      Sentry.with_child_span(op: op, description: description) do |span|
        if span
          attributes.each { |key, value| span.set_data(key, value) unless value.nil? }
        end

        begin
          yield span
        rescue Exception
          span&.set_status("internal_error")
          raise
        end
      end
    end

    def sentry_active?
      defined?(Sentry) && Sentry.initialized?
    end

    def set_scope_user(user_identifier)
      return unless sentry_active? && user_identifier.present?

      scope = Sentry.get_current_scope
      # Web requests already attach the richer authenticated user
      # (Authentication#set_sentry_user); only fill the gap in background jobs.
      scope.set_user(id: user_identifier) if scope && scope.user.blank?
    end

    def increment_span_data(span, key, value)
      current = span.data&.dig(key).to_i
      span.set_data(key, current + value.to_i)
    end

    def format_messages(messages)
      case messages
      when String
        messages.present? ? [ text_message("user", messages) ] : []
      when Array
        messages.filter_map { |message| format_message(message) }
      else
        []
      end
    end

    def format_message(message)
      return nil unless message.respond_to?(:[])

      role = (message[:role] || message["role"]).to_s
      content = message[:content] || message["content"]
      return nil if role.blank? || !content.is_a?(String) || content.blank?

      text_message(role, content)
    end

    def text_message(role, content)
      { role: role, parts: [ { type: "text", content: content } ] }
    end

    # Accepts a plain string or Anthropic-style system blocks
    # ([{ type: "text", text: "..." }, ...]).
    def format_instructions(instructions)
      case instructions
      when String
        instructions
      when Array
        instructions.filter_map { |block| block[:text] || block["text"] if block.respond_to?(:[]) }.join("\n")
      end
    end

    def truncate_content(text)
      text.to_s.truncate(MAX_CONTENT_LENGTH)
    end

    def log_instrumentation_failure(method_name, error)
      Rails.logger.warn("LlmInstrumentation.#{method_name} failed: #{error.class}: #{error.message}")
    end
end
