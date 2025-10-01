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
    # Sends the prepared message and context to the LLM and returns the LLM's response data.
    # @param [Proc] streamer - A proc that will receive streamed chunks from the LLM.
    # @param [Array<Hash>] function_results - Results from previously executed functions to include in the request.
    # @param [String, nil] previous_response_id - ID of a prior response to continue a thread, or nil to start fresh.
    # @return [Object] The parsed response data returned by the LLM.
    # @raise [Exception] Raises the error returned by the LLM when the response indicates failure.
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
    # Lazily initializes and returns the listeners registry for this responder.
    # The registry maps event names (symbols) to arrays of listener blocks.
    # @return [Hash] A hash where each key is an event name symbol and each value is an Array of listener blocks (Procs).
    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    ##
    # Chat session identifier as a string.
    # @return [String, nil] The associated chat's `id` converted to a string, or `nil` if no chat is present.
    def chat_session_id
      chat&.id&.to_s
    end

    ##
    # Compute a SHA256 hex digest of the chat's user_id to serve as a user identifier.
    # @return [String, nil] The SHA256 hex digest of the chat's user_id, or `nil` if the chat or its `user_id` is not present.
    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    # @return [Chat, nil] The associated chat or `nil`.
    def chat
      @chat ||= message.chat
    end
end
