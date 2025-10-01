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
  # Automatically detect merchant entities for a collection of transactions.
  # @param [Array] transactions - Transactions to analyze for merchant detection (max 25).
  # @param [Array] user_merchants - Optional user-provided merchants to guide detection.
  # @param [String] model - Optional model identifier to use for detection.
  # @raise [Error] If more than 25 transactions are provided ("Too many transactions to auto-detect merchants. Max is 25 per request.").
  # @return [Array] An array of merchant-detection result objects; each element can be converted to a hash via `to_h`.
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
  # Generates a chat response for the given prompt using the configured OpenAI client and options.
  # If a streamer is provided, parsed stream chunks are forwarded to it and the final response chunk is returned;
  # otherwise the full parsed response is returned.
  # @param [String] prompt - The user prompt or conversation input.
  # @param [String] model - The model identifier to use (e.g., "gpt-4.1").
  # @param [String, nil] instructions - Optional high-level instructions to guide the model's behavior.
  # @param [Array<Hash>] functions - Optional tool/function definitions available to the model.
  # @param [Array<Hash>] function_results - Optional results from previously executed functions to include in the context.
  # @param [Proc, nil] streamer - Optional callable that receives parsed stream chunks as they arrive.
  # @param [String, nil] previous_response_id - Optional id of a previous provider response to continue from.
  # @param [String, nil] session_id - Optional session identifier to include in logging/telemetry.
  # @param [String, nil] user_identifier - Optional user identifier to include in logging/telemetry.
  # @return [Object] The parsed chat response (when streaming, the returned value is the final parsed response chunk; otherwise the parsed response object containing messages and usage metadata).
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
    # Provides a configured Langfuse client when Langfuse credentials are available.
    # @return [Langfuse, nil] A Langfuse client stored in `@langfuse_client` when both `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` are present; `nil` otherwise.
    def langfuse_client
      return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

      @langfuse_client = Langfuse.new
    end

    ##
    # Send generation metadata to Langfuse when a Langfuse client is configured.
    #
    # @param [String] name - Logical name for the generation event (e.g., "chat_response").
    # @param [String] model - Model identifier used to produce the generation.
    # @param [Hash] input - The input payload sent to the model.
    # @param [Object] output - The generation output to record (typically messages or text).
    # @param [Hash, nil] usage - Optional usage details returned by the provider (e.g., token counts).
    # @param [String, nil] session_id - Optional session identifier to associate with the trace.
    # @param [String, nil] user_identifier - Optional user identifier to associate with the trace as `user_id`.
    #
    # If no Langfuse client is configured, the method returns immediately. Any errors raised while recording the trace are rescued and a warning is logged without propagating the error.
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
