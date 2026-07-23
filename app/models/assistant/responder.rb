class Assistant::Responder
  ToolCallLimitError = Class.new(StandardError)
  EmptyResponseError = Class.new(StandardError)
  DEFAULT_MAX_TOOL_CALL_ITERATIONS = 5

  def initialize(message:, instructions:, function_tool_caller:, llm:)
    @message = message
    @instructions = instructions
    @function_tool_caller = function_tool_caller
    @llm = llm
  end

  def on(event_name, &block)
    listeners[event_name.to_sym] << block
  end

  def respond(previous_response_id: nil)
    response, response_has_text = request_response(previous_response_id: previous_response_id)
    iteration = 0

    while response.function_requests.any?
      iteration += 1
      if iteration > max_tool_call_iterations
        raise ToolCallLimitError,
              "Assistant exceeded the tool-call limit of #{max_tool_call_iterations} for one response"
      end

      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)

      emit(:response, {
        id: response.id,
        function_tool_calls: function_tool_calls
      })

      response, response_has_text = request_response(
        function_results: function_tool_calls.map(&:to_result),
        previous_response_id: response.id
      )
    end

    raise EmptyResponseError, "Assistant returned neither text nor tool calls" unless response_has_text

    emit(:response, { id: response.id })
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def request_response(function_results: [], previous_response_id: nil)
      response_has_text = false

      streamer = proc do |chunk|
        if chunk.type == "output_text" && chunk.data.present?
          response_has_text = true
          emit(:output_text, chunk.data)
        end
      end

      response = get_llm_response(
        streamer: streamer,
        function_results: function_results,
        previous_response_id: previous_response_id
      )

      response_has_text ||= response.messages.any? { |response_message| response_message.output_text.present? }
      [ response, response_has_text ]
    end

    def max_tool_call_iterations
      configured = Integer(ENV.fetch("ASSISTANT_MAX_TOOL_CALL_ITERATIONS", DEFAULT_MAX_TOOL_CALL_ITERATIONS).to_s, 10)
      configured.positive? ? configured : DEFAULT_MAX_TOOL_CALL_ITERATIONS
    rescue ArgumentError
      DEFAULT_MAX_TOOL_CALL_ITERATIONS
    end

    def get_llm_response(streamer:, function_results: [], previous_response_id: nil)
      response = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        messages: openai_messages_payload,
        conversation_history: chat_message_records,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      unless response.success?
        raise response.error
      end

      response.data
    end

    def emit(event_name, payload = nil)
      listeners[event_name.to_sym].each { |block| block.call(payload) }
    end

    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    def chat_session_id
      chat&.id&.to_s
    end

    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    def chat
      @chat ||= message.chat
    end

    # Memoized fetch — both `chat_message_records` and `openai_messages_payload`
    # derive their shape from this one in-memory array so a single chat turn
    # fires one history query instead of two.
    def complete_chat_messages
      return @complete_chat_messages if defined?(@complete_chat_messages)

      @complete_chat_messages =
        if chat&.messages
          chat.messages
              .where(type: [ "UserMessage", "AssistantMessage" ], status: "complete")
              .includes(:tool_calls)
              .ordered
              .to_a
        else
          []
        end
    end

    # Raw Message records preceding the current turn — providers that build
    # their own native message shape (Anthropic) consume this directly so they
    # do not have to round-trip through the OpenAI-shaped payload below.
    def chat_message_records
      complete_chat_messages.reject { |m| m.id == message.id }
    end

    # Builds the OpenAI-shaped messages payload (role: "user" | "assistant" |
    # "tool"; tool_call_id pairing) consumed by Provider::Openai's generic
    # chat path. Anthropic uses chat_message_records instead.
    def openai_messages_payload
      messages = []
      complete_chat_messages.each do |chat_message|
        if chat_message.tool_calls.any?
          messages << {
            role: chat_message.role,
            content: chat_message.content || "",
            tool_calls: chat_message.tool_calls.map(&:to_tool_call)
          }

          chat_message.tool_calls.map(&:to_result).each do |fn_result|
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

        elsif !chat_message.content.blank?
          messages << { role: chat_message.role, content: chat_message.content || "" }
        end
      end
      messages
    end
end
