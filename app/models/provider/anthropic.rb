class Provider::Anthropic < Provider
  include LlmConcept
  include LangfuseTraceable

  # Subclass so errors caught in this provider are raised as Provider::Anthropic::Error
  Error = Class.new(Provider::Error)

  # Supported Anthropic model prefixes
  DEFAULT_ANTHROPIC_MODEL_PREFIXES = %w[claude].freeze
  DEFAULT_MODEL = "claude-sonnet-4-6"

  # Models that read images and PDFs, which Ai::LegacyEnvConfig reads for `vision` and
  # `documents`.
  VISION_CAPABLE_MODEL_PREFIXES = %w[claude].freeze

  def self.effective_model
    # Use ENV[].presence rather than ENV.fetch(KEY, default) so the Setting
    # lookup is only performed when the ENV var is actually absent — otherwise
    # the default arg is evaluated eagerly on every call.
    configured_model = ENV["ANTHROPIC_MODEL"].presence || Setting.anthropic_model
    configured_model.presence || DEFAULT_MODEL
  end

  def self.configured?
    ENV["ANTHROPIC_ACCESS_TOKEN"].present? ||
      ENV["ANTHROPIC_API_KEY"].present? ||
      Setting.anthropic_access_token.present?
  end

  def initialize(access_token, base_url: nil, model: nil)
    client_options = { api_key: access_token }
    client_options[:base_url] = base_url if base_url.present?
    client_options[:timeout] = ENV.fetch("ANTHROPIC_REQUEST_TIMEOUT", 600).to_i

    @client = ::Anthropic::Client.new(**client_options)
    @base_url = base_url

    if custom_endpoint? && model.blank?
      raise Error, "Model is required when using a custom Anthropic-compatible endpoint"
    end

    @default_model = model.presence || DEFAULT_MODEL
  end

  def supports_model?(model)
    # Custom endpoints (Bedrock, Vertex, or other Anthropic-compatible proxies)
    # use their own model-ID conventions — e.g. Bedrock IDs look like
    # `anthropic.claude-sonnet-4-5-20250929-v1:0`. Mirror the OpenAI provider
    # and bypass the prefix gate when the caller has wired a custom base_url.
    return true if custom_endpoint?

    DEFAULT_ANTHROPIC_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def provider_name
    custom_endpoint? ? "Custom Anthropic-compatible (#{@base_url})" : "Anthropic"
  end

  def supported_models_description
    if custom_endpoint?
      "configured model: #{@default_model}"
    else
      "models starting with: #{DEFAULT_ANTHROPIC_MODEL_PREFIXES.join(', ')}"
    end
  end

  def custom_endpoint?
    @base_url.present?
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil,
    family: nil
  )
    with_provider_response do
      chat_config = ChatConfig.new(
        prompt: prompt,
        instructions: instructions,
        functions: functions,
        function_results: function_results,
        tool_choice: tool_choice,
        conversation_history: conversation_history,
        default_max_tokens: default_max_tokens
      )

      request_params = chat_config.build_request(model: model)

      trace = create_langfuse_trace(
        name: "anthropic.chat_response",
        input: { messages: request_params[:messages], system: request_params[:system_] },
        session_id: session_id,
        user_identifier: user_identifier
      )

      partial_usage_recorded = false

      begin
        parsed, usage =
          if streamer.present?
            stream_chat_response(
              streamer: streamer,
              request_params: request_params,
              on_partial: ->(partial_usage) {
                record_llm_usage(family: family, model: model, operation: "chat", usage: partial_usage)
                partial_usage_recorded = true
              }
            )
          else
            sync_chat_response(request_params: request_params)
          end

        log_langfuse_generation(
          name: "chat_response",
          model: model,
          input: request_params[:messages],
          output: parsed.messages.map(&:output_text).join("\n"),
          usage: usage,
          trace: trace
        )
        # Record once. On a normal stream `on_partial` never fires (it only runs
        # from stream_chat_response's rescue on a mid-stream error, which
        # re-raises past here), so today this is the sole recorder. Guard it
        # anyway so a future change that emits partial usage on success can't
        # silently double-bill — the symptom we chased in the #1984 review.
        record_llm_usage(family: family, model: model, operation: "chat", usage: usage) unless partial_usage_recorded

        parsed
      rescue => e
        log_langfuse_generation(
          name: "chat_response",
          model: model,
          input: request_params[:messages],
          error: e,
          trace: trace
        )
        record_llm_usage(family: family, model: model, operation: "chat", error: e) unless partial_usage_recorded
        raise
      end
    end
  end

  private
    attr_reader :client

    def default_max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def sync_chat_response(request_params:)
      raw = client.messages.create(**request_params)
      parsed = ChatParser.new(raw).parsed
      usage = build_usage_hash(raw.usage)
      [ parsed, usage ]
    end

    def stream_chat_response(streamer:, request_params:, on_partial: nil)
      final_message = nil
      stream = client.messages.stream(**request_params)

      # If `stream.each` raises mid-iteration (network drop, client abort),
      # we still want to surface whatever tokens accumulated so the cost
      # ledger doesn't lose partial-output billing.
      begin
        stream.each do |event|
          case event
          when ::Anthropic::Streaming::TextEvent
            streamer.call(
              Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: event.text, usage: nil)
            )
          when ::Anthropic::Streaming::MessageStopEvent
            final_message = event.message
          end
        end
      rescue => mid_stream_error
        partial = safe_accumulated_message(stream)
        on_partial&.call(build_usage_hash(partial&.usage)) if partial
        raise mid_stream_error
      end

      final_message ||= safe_accumulated_message(stream)
      parsed = ChatParser.new(final_message).parsed
      usage = build_usage_hash(final_message.usage)

      streamer.call(
        Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: parsed, usage: usage)
      )

      [ parsed, usage ]
    end

    def safe_accumulated_message(stream)
      stream.accumulated_message
    rescue StandardError
      nil
    end

    def build_usage_hash(raw_usage)
      return {} unless raw_usage

      input = raw_usage.input_tokens.to_i
      output = raw_usage.output_tokens.to_i
      hash = {
        "input_tokens" => input,
        "output_tokens" => output,
        "total_tokens" => input + output
      }

      if raw_usage.respond_to?(:cache_creation_input_tokens) && raw_usage.cache_creation_input_tokens
        hash["cache_creation_input_tokens"] = raw_usage.cache_creation_input_tokens
      end
      if raw_usage.respond_to?(:cache_read_input_tokens) && raw_usage.cache_read_input_tokens
        hash["cache_read_input_tokens"] = raw_usage.cache_read_input_tokens
      end

      hash
    end

    def log_langfuse_generation(name:, model:, input:, trace:, output: nil, usage: nil, error: nil)
      return unless langfuse_client

      generation = trace&.generation(
        name: name,
        model: model,
        input: input,
        start_time: trace.start_time
      )

      if error
        generation&.end(
          output: { error: error.message, details: error.respond_to?(:details) ? error.details : nil },
          level: "ERROR"
        )
        finish_langfuse_trace(trace: trace, output: { error: error.message }, level: "ERROR")
      else
        generation&.end(output: output, usage: usage)
        finish_langfuse_trace(trace: trace, output: output)
      end
    rescue => e
      Rails.logger.warn("Langfuse logging failed: #{e.class}: #{e.message}")
    end

    def record_llm_usage(family:, model:, operation:, usage: nil, error: nil)
      return unless family

      if error.present?
        http_status_code = extract_http_status_code(error)

        family.llm_usages.create!(
          provider: "anthropic",
          model: model,
          operation: operation,
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          estimated_cost: nil,
          metadata: {
            error: safe_error_message(error),
            http_status_code: http_status_code
          }
        )
        return
      end

      return unless usage

      prompt_tokens = usage["input_tokens"] || 0
      completion_tokens = usage["output_tokens"] || 0
      total_tokens = usage["total_tokens"] || (prompt_tokens + completion_tokens)

      estimated_cost = LlmUsage.calculate_cost(
        model: model,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        cache_creation_tokens: usage["cache_creation_input_tokens"],
        cache_read_tokens: usage["cache_read_input_tokens"]
      )

      family.llm_usages.create!(
        provider: "anthropic",
        model: model,
        operation: operation,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        cache_creation_tokens: usage["cache_creation_input_tokens"],
        cache_read_tokens: usage["cache_read_input_tokens"],
        estimated_cost: estimated_cost,
        metadata: {}
      )
    rescue => e
      Rails.logger.error("Failed to record LLM usage: #{e.message}")
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
