class Provider::Openclaw < Provider
  include LlmConcept

  Error = Class.new(Provider::Error)
  ConnectionError = Class.new(Error)
  UnavailableError = Class.new(Error)

  DEFAULT_MODEL = "openclaw"
  SUPPORTED_MODEL_PREFIXES = %w[openclaw].freeze

  def self.effective_model
    DEFAULT_MODEL
  end

  def initialize(gateway_url: nil, connection_timeout: nil, response_timeout: nil)
    @gateway_url = gateway_url || Rails.configuration.x.openclaw.gateway_url
    @connection_timeout = connection_timeout || Rails.configuration.x.openclaw.connection_timeout
    @response_timeout = response_timeout || Rails.configuration.x.openclaw.response_timeout
    @client = WebsocketClient.new(
      gateway_url: @gateway_url,
      connection_timeout: @connection_timeout,
      response_timeout: @response_timeout
    )
  end

  def supports_model?(model)
    SUPPORTED_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def provider_name
    "OpenClaw (Local)"
  end

  def supported_models_description
    "models starting with: #{SUPPORTED_MODEL_PREFIXES.join(', ')}"
  end

  def available?
    @client.available?
  rescue => e
    Rails.logger.warn("OpenClaw availability check failed: #{e.message}")
    false
  end

  def auto_categorize(transactions: [], user_categories: [], model: "", family: nil, json_mode: nil)
    raise NotImplementedError, "Auto-categorization not supported via OpenClaw. Use OpenAI provider."
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "", family: nil, json_mode: nil)
    raise NotImplementedError, "Merchant detection not supported via OpenClaw. Use OpenAI provider."
  end

  def supports_pdf_processing?(model: DEFAULT_MODEL)
    false
  end

  def process_pdf(pdf_content:, model: "", family: nil)
    raise NotImplementedError, "PDF processing not supported via OpenClaw. Use OpenAI provider."
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil,
    family: nil
  )
    with_provider_response do
      raise UnavailableError, "OpenClaw gateway is not available at #{@gateway_url}" unless available?

      full_prompt = build_prompt(
        prompt,
        instructions: instructions,
        function_results: function_results
      )

      collected_chunks = []

      stream_proxy = if streamer.present?
        proc do |chunk|
          streamer.call(chunk)
          collected_chunks << chunk
        end
      end

      raw_response = @client.send_message(
        full_prompt,
        functions: functions,
        streamer: stream_proxy
      )

      parsed = ChatParser.new(raw_response).parsed

      record_llm_usage(family: family, model: model, operation: "chat")

      if streamer.present? && collected_chunks.none? { |c| c.type == "response" }
        parsed.messages.each do |message|
          if message.output_text.present?
            streamer.call(ChatStreamChunk.new(type: "output_text", data: message.output_text, usage: nil))
          end
        end
        streamer.call(ChatStreamChunk.new(type: "response", data: parsed, usage: nil))
      end

      parsed
    end
  end

  private
    attr_reader :client

    ChatStreamChunk = Provider::LlmConcept::ChatStreamChunk

    def build_prompt(prompt, instructions: nil, function_results: [])
      parts = []

      parts << "[System Instructions]\n#{instructions}" if instructions.present?
      parts << prompt

      if function_results.any?
        parts << "\n[Tool Results]"
        function_results.each do |result|
          output = result[:output]
          output_str = output.is_a?(String) ? output : output.to_json
          parts << "[#{result[:name]}]: #{output_str}"
        end
      end

      parts.join("\n\n")
    end

    def record_llm_usage(family:, model:, operation:, usage: nil, error: nil)
      return unless family

      begin
        inferred_provider = LlmUsage.infer_provider(model)
        family.llm_usages.create!(
          provider: inferred_provider,
          model: model,
          operation: operation,
          prompt_tokens: usage&.dig("prompt_tokens") || usage&.dig("input_tokens") || 0,
          completion_tokens: usage&.dig("completion_tokens") || usage&.dig("output_tokens") || 0,
          total_tokens: usage&.dig("total_tokens") || 0,
          estimated_cost: nil,
          metadata: error.present? ? { error: error.message } : {}
        )
      rescue => e
        Rails.logger.error("Failed to record OpenClaw usage: #{e.message}")
      end
    end
end
