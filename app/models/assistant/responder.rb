class Assistant::Responder
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
    # For the first response
    streamer = proc do |chunk|
      case chunk.type
      when "output_text"
        emit(:output_text, chunk.data)
      when "response"
        response = chunk.data

        if response.function_requests.any?
          handle_follow_up_response(response)
        else
          emit(:response, { id: response.id })
        end
      end
    end

    get_llm_response(streamer: streamer, previous_response_id: previous_response_id)
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def handle_follow_up_response(response)
      streamer = proc do |chunk|
        case chunk.type
        when "output_text"
          emit(:output_text, chunk.data)
        when "response"
          # We do not currently support function executions for a follow-up response (avoid recursive LLM calls that could lead to high spend)
          emit(:response, { id: chunk.data.id })
        end
      end

      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)

      emit(:response, {
        id: response.id,
        function_tool_calls: function_tool_calls
      })

      # Get follow-up response with tool call results
      get_llm_response(
        streamer: streamer,
        function_results: function_tool_calls.map(&:to_result),
        previous_response_id: response.id
      )
    end

    ##
    # Requests a chat response from the configured LLM and returns the response data.
    # @param [Object] streamer - An object that receives streaming events from the LLM.
    # @param [Array<Hash>] function_results - Results produced by previously executed function calls to include in the LLM request.
    # @param [String, nil] previous_response_id - ID of a prior response to continue the conversation, or `nil` to start a new one.
    # @return [Object] The data payload from the LLM response.
    # @raise [Exception] Raises the LLM response error when the response indicates failure.
    def get_llm_response(streamer:, function_results: [], previous_response_id: nil)
      response = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier
      )

      unless response.success?
        raise response.error
      end

      response.data
    end

    def emit(event_name, payload = nil)
      listeners[event_name.to_sym].each { |block| block.call(payload) }
    end

    ##
    # Provides the internal registry that maps event names to arrays of listener blocks.
    # The hash is lazily initialized and memoized; accessing a missing key automatically creates and returns an empty array for that key.
    # @return [Hash] A hash mapping event names to arrays of listener blocks.
    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    ##
    # Current chat's id as a string, or nil if unavailable.
    # @return [String, nil] The chat id converted to a String, or `nil` when no chat or id is present.
    def chat_session_id
      chat&.id&.to_s
    end

    ##
    # Compute a SHA256 hex identifier derived from the chat's user_id.
    # @return [String, nil] The SHA256 hex digest of `chat.user_id`, or `nil` if no chat or no user_id is present.
    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    # @return [Chat, nil] The chat associated with the message, or `nil` if none.
    def chat
      @chat ||= message.chat
    end
end
