class Provider::Openai < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Openai::Error
  Error = Class.new(Provider::Error)

  # Supported OpenAI model prefixes (e.g., "gpt-4" matches "gpt-4", "gpt-4.1", "gpt-4-turbo", etc.)
  DEFAULT_OPENAI_MODEL_PREFIXES = %w[gpt-4 gpt-5 o1 o3]
  DEFAULT_MODEL = "gpt-5-nano"

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

      result = AutoCategorizer.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_categories: user_categories,
        custom_provider: custom_provider?
      ).auto_categorize

      log_langfuse_generation(
        name: "auto_categorize",
        model: effective_model,
        input: { transactions: transactions, user_categories: user_categories },
        output: result.map(&:to_h)
      )

      result
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-detect merchants. Max is 25 per request." if transactions.size > 25

      effective_model = model.presence || @default_model

      result = AutoMerchantDetector.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_merchants: user_merchants,
        custom_provider: custom_provider?
      ).auto_detect_merchants

      log_langfuse_generation(
        name: "auto_detect_merchants",
        model: effective_model,
        input: { transactions: transactions, user_merchants: user_merchants },
        output: result.map(&:to_h)
      )

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
              streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: message.output_text))
            end
          end

          # Emit response chunk
          streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: parsed))
        end

        parsed
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

      # Add function results as tool messages
      function_results.each do |fn_result|
        # Convert output to JSON string if it's not already a string
        # OpenAI API requires content to be either a string or array of objects
        content = fn_result[:output].is_a?(String) ? fn_result[:output] : fn_result[:output].to_json

        messages << {
          role: "tool",
          tool_call_id: fn_result[:call_id],
          content: content
        }
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
