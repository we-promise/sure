class Provider::Openai < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Openai::Error
  Error = Class.new(Provider::Error)

  MODELS = %w[gpt-4.1]

  def initialize(access_token)
    @client = ::OpenAI::Client.new(access_token: access_token)
  end

  def supports_model?(model)
    MODELS.include?(model)
  end

  def auto_categorize(transactions: [], user_categories: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-categorize. Max is 25 per request." if transactions.size > 25

      result = AutoCategorizer.new(
        client,
        model: model,
        transactions: transactions,
        user_categories: user_categories
      ).auto_categorize

      log_langfuse_generation(
        name: "auto_categorize",
        model: model,
        input: { transactions: transactions, user_categories: user_categories },
        output: result.map(&:to_h)
      )

      result
    end
  end

  ##
  # Detects merchants for a list of transactions using the provider's OpenAI client.
  # @param [Array<Hash>] transactions - Transactions to analyze (maximum 25).
  # @param [Array<Hash>] user_merchants - Known user merchants to consider during detection.
  # @param [String] model - Model identifier to use for detection.
  # @return [Array<Object>] Merchant detection results; each element implements `to_h`.
  # @raise [Error] If more than 25 transactions are provided.
  def auto_detect_merchants(transactions: [], user_merchants: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-detect merchants. Max is 25 per request." if transactions.size > 25

      result = AutoMerchantDetector.new(
        client,
        model: model,
        transactions: transactions,
        user_merchants: user_merchants
      ).auto_detect_merchants

      log_langfuse_generation(
        name: "auto_detect_merchants",
        model: model,
        input: { transactions: transactions, user_merchants: user_merchants },
        output: result.map(&:to_h)
      )

      result
    end
  end

  ##
  # Generate a chat response from the configured OpenAI client, supporting function tools and optional streaming.
  # @param [Object] prompt - The prompt to send; typically a string or structured messages accepted by ChatConfig#build_input.
  # @param [String] model - The model identifier to use (e.g., "gpt-4.1").
  # @param [String, nil] instructions - Optional high-level instructions to pass to the model.
  # @param [Array] functions - An array of function/tool definitions available to the model.
  # @param [Array] function_results - Results from previously called functions to include in the context.
  # @param [Proc, nil] streamer - Optional callable that will be invoked with parsed streaming chunks as they arrive.
  # @param [String, nil] previous_response_id - Optional ID of a previous model response to continue a thread.
  # @param [String, nil] session_id - Optional session identifier propagated to logging.
  # @param [String, nil] user_identifier - Optional user identifier propagated to logging.
  # @return [Object] When not streaming, returns the parsed chat response object. When streaming, returns the response chunk data extracted from the stream.
  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    with_provider_response do
      chat_config = ChatConfig.new(
        functions: functions,
        function_results: function_results
      )

      collected_chunks = []

      # Proxy that converts raw stream to "LLM Provider concept" stream
      stream_proxy = if streamer.present?
        proc do |chunk|
          parsed_chunk = ChatStreamParser.new(chunk).parsed

          unless parsed_chunk.nil?
            streamer.call(parsed_chunk)
            collected_chunks << parsed_chunk
          end
        end
      else
        nil
      end

      input_payload = chat_config.build_input(prompt)

      raw_response = client.responses.create(parameters: {
        model: model,
        input: input_payload,
        instructions: instructions,
        tools: chat_config.tools,
        previous_response_id: previous_response_id,
        stream: stream_proxy
      })

      # If streaming, Ruby OpenAI does not return anything, so to normalize this method's API, we search
      # for the "response chunk" in the stream and return it (it is already parsed)
      if stream_proxy.present?
        response_chunk = collected_chunks.find { |chunk| chunk.type == "response" }
        response = response_chunk.data
        log_langfuse_generation(
          name: "chat_response",
          model: model,
          input: input_payload,
          output: response.messages.map(&:output_text).join("\n"),
          session_id: session_id,
          user_identifier: user_identifier
        )
        response
      else
        parsed = ChatParser.new(raw_response).parsed
        log_langfuse_generation(
          name: "chat_response",
          model: model,
          input: input_payload,
          output: parsed.messages.map(&:output_text).join("\n"),
          usage: raw_response["usage"],
          session_id: session_id,
          user_identifier: user_identifier
        )
        parsed
      end
    end
  end

  private
    attr_reader :client

    ##
    # Return a Langfuse client when API keys are configured.
    #
    # Returns a memoized Langfuse client if ENV["LANGFUSE_PUBLIC_KEY"] and
    # ENV["LANGFUSE_SECRET_KEY"] are present; returns nil otherwise.
    # @return [Langfuse, nil] The Langfuse client instance or nil when not configured.
    def langfuse_client
      return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

      @langfuse_client = Langfuse.new
    end

    ##
    # Logs a generation record and trace to Langfuse if configured.
    # @param [String] name - Identifier for the generation event (e.g. "chat_response").
    # @param [String] model - Model identifier used for the generation.
    # @param [Object] input - The input payload sent to the provider; recorded as trace input.
    # @param [Object] output - The generated output to record and attach to the trace.
    # @param [Hash, nil] usage - Optional usage or consumption metrics to record.
    # @param [String, nil] session_id - Optional session identifier to associate with the trace.
    # @param [String, nil] user_identifier - Optional user identifier to associate with the trace.
    def log_langfuse_generation(name:, model:, input:, output:, usage: nil, session_id: nil, user_identifier: nil)
      return unless langfuse_client

      trace = langfuse_client.trace(
        name: "openai.#{name}",
        input: input,
        session_id: session_id,
        user_id: user_identifier
      )
      trace.generation(
        name: name,
        model: model,
        input: input,
        output: output,
        usage: usage,
        session_id: session_id,
        user_id: user_identifier
      )
      trace.update(output: output)
    rescue => e
      Rails.logger.warn("Langfuse logging failed: #{e.message}")
    end
end
