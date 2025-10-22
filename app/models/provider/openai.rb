class Provider::Openai < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Openai::Error
  Error = Class.new(Provider::Error)

  # Supported OpenAI model prefixes (e.g., "gpt-4" matches "gpt-4", "gpt-4.1", "gpt-4-turbo", etc.)
  DEFAULT_OPENAI_MODEL_PREFIXES = %w[gpt-4 gpt-5 o1 o3]
  DEFAULT_MODEL = "gpt-4.1"

  def initialize(access_token, uri_base: nil, model: nil)
    client_options = { access_token: access_token }
    client_options[:uri_base] = uri_base if uri_base.present?

    @client = ::OpenAI::Client.new(**client_options)
    @uri_base = uri_base
    if custom_provider? && model.blank?
      raise Error, "Model is required when using a custom OpenAI‑compatible provider"
    end
    @default_model = model.presence || DEFAULT_MODEL
  end

  def supports_model?(model)
    # If using custom uri_base, support any model
    return true if custom_provider?

    # Otherwise, check if model starts with any supported OpenAI prefix
    DEFAULT_OPENAI_MODEL_PREFIXES.any? { |prefix| model.start_with?(prefix) }
  end

  def custom_provider?
    @uri_base.present?
  end

  def auto_categorize(transactions: [], user_categories: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-categorize. Max is 25 per request." if transactions.size > 25

      effective_model = model.presence || @default_model

      trace = create_langfuse_trace(
        name: "openai.auto_categorize",
        input: { transactions: transactions, user_categories: user_categories }
      )

      result = AutoCategorizer.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_categories: user_categories,
        custom_provider: custom_provider?,
        langfuse_trace: trace
      ).auto_categorize

      trace&.update(output: result.map(&:to_h))

      result
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-detect merchants. Max is 25 per request." if transactions.size > 25

      effective_model = model.presence || @default_model

      trace = create_langfuse_trace(
        name: "openai.auto_detect_merchants",
        input: { transactions: transactions, user_merchants: user_merchants }
      )

      result = AutoMerchantDetector.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_merchants: user_merchants,
        custom_provider: custom_provider?,
        langfuse_trace: trace
      ).auto_detect_merchants

      trace&.update(output: result.map(&:to_h))

      result
    end
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
    user_identifier: nil
  )
    if custom_provider?
      generic_chat_response(
        prompt: prompt,
        model: model,
        instructions: instructions,
        functions: functions,
        function_results: function_results,
        streamer: streamer,
        session_id: session_id,
        user_identifier: user_identifier
      )
    else
      native_chat_response(
        prompt: prompt,
        model: model,
        instructions: instructions,
        functions: functions,
        function_results: function_results,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: session_id,
        user_identifier: user_identifier
      )
    end
  end

  private
    attr_reader :client

    def native_chat_response(
      prompt:,
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

        begin
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
            usage = response_chunk.usage
            log_langfuse_generation(
              name: "chat_response",
              model: model,
              input: input_payload,
              output: response.messages.map(&:output_text).join("\n"),
              usage: usage,
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
        rescue => e
          log_langfuse_generation(
            name: "chat_response",
            model: model,
            input: input_payload,
            error: e,
            session_id: session_id,
            user_identifier: user_identifier
          )
          raise
        end
      end
    end

    def generic_chat_response(
      prompt:,
      model:,
      instructions: nil,
      functions: [],
      function_results: [],
      streamer: nil,
      session_id: nil,
      user_identifier: nil
    )
      with_provider_response do
        messages = build_generic_messages(
          prompt: prompt,
          instructions: instructions,
          function_results: function_results
        )

        tools = build_generic_tools(functions)

        # Force synchronous calls for generic chat (streaming not supported for custom providers)
        params = {
          model: model,
          messages: messages
        }
        params[:tools] = tools if tools.present?

        begin
          raw_response = client.chat(parameters: params)

          parsed = GenericChatParser.new(raw_response).parsed

          log_langfuse_generation(
            name: "chat_response",
            model: model,
            input: messages,
            output: parsed.messages.map(&:output_text).join("\n"),
            usage: raw_response["usage"],
            session_id: session_id,
            user_identifier: user_identifier
          )

          # If a streamer was provided, manually call it with the parsed response
          # to maintain the same contract as the streaming version
          if streamer.present?
            # Emit output_text chunks for each message
            parsed.messages.each do |message|
              if message.output_text.present?
                streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: message.output_text, usage: nil))
              end
            end

            # Emit response chunk
            streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: parsed, usage: raw_response["usage"]))
          end

          parsed
        rescue => e
          log_langfuse_generation(
            name: "chat_response",
            model: model,
            input: messages,
            error: e,
            session_id: session_id,
            user_identifier: user_identifier
          )
          raise
        end
      end
    end

    def build_generic_messages(prompt:, instructions: nil, function_results: [])
      messages = []

      # Add system message if instructions present
      if instructions.present?
        messages << { role: "system", content: instructions }
      end

      # Add user prompt
      messages << { role: "user", content: prompt }

      # If there are function results, we need to add the assistant message that made the tool calls
      # followed by the tool messages with the results
      if function_results.any?
        # Build assistant message with tool_calls
        tool_calls = function_results.map do |fn_result|
          {
            id: fn_result[:call_id],
            type: "function",
            function: {
              name: fn_result[:name],
              arguments: fn_result[:arguments]
            }
          }
        end

        messages << {
          role: "assistant",
          content: nil,
          tool_calls: tool_calls
        }

        # Add function results as tool messages
        function_results.each do |fn_result|
          # Convert output to JSON string if it's not already a string
          # OpenAI API requires content to be either a string or array of objects
          # Handle nil explicitly to avoid serializing to "null"
          output = fn_result[:output]
          content = if output.nil?
            ""
          elsif output.is_a?(String)
            output
          else
            output.to_json
          end

          messages << {
            role: "tool",
            tool_call_id: fn_result[:call_id],
            name: fn_result[:name],
            content: content
          }
        end
      end

      messages
    end

    def build_generic_tools(functions)
      return [] if functions.blank?

      functions.map do |fn|
        {
          type: "function",
          function: {
            name: fn[:name],
            description: fn[:description],
            parameters: fn[:params_schema],
            strict: fn[:strict]
          }
        }
      end
    end

    def langfuse_client
      return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

      @langfuse_client = Langfuse.new
    end

    def create_langfuse_trace(name:, input:, session_id: nil, user_identifier: nil)
      return unless langfuse_client

      langfuse_client.trace(
        name: name,
        input: input,
        session_id: session_id,
        user_id: user_identifier
      )
    rescue => e
      Rails.logger.warn("Langfuse trace creation failed: #{e.message}")
      nil
    end

    def log_langfuse_generation(name:, model:, input:, output: nil, usage: nil, error: nil, session_id: nil, user_identifier: nil)
      return unless langfuse_client

      trace = create_langfuse_trace(
        name: "openai.#{name}",
        input: input,
        session_id: session_id,
        user_identifier: user_identifier
      )

      generation = trace&.generation(
        name: name,
        model: model,
        input: input
      )

      if error
        generation&.end(
          output: { error: error.message, details: error.respond_to?(:details) ? error.details : nil },
          level: "ERROR"
        )
        trace&.update(
          output: { error: error.message },
          level: "ERROR"
        )
      else
        generation&.end(output: output, usage: usage)
        trace&.update(output: output)
      end
    rescue => e
      Rails.logger.warn("Langfuse logging failed: #{e.message}")
    end
end
