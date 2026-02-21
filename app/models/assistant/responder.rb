class Assistant::Responder
  MAX_FOLLOW_UP_DEPTH = 5

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
    # Track whether response was handled by streamer
    response_handled = false

    # For the first response
    streamer = proc do |chunk|
      case chunk.type
      when "output_text"
        emit(:output_text, chunk.data)
      when "response"
        response = chunk.data
        response_handled = true

        if response.function_requests.any?
          handle_follow_up_response(response, depth: 0)
        else
          emit(:response, { id: response.id })
        end
      end
    end

    response = get_llm_response(streamer: streamer, previous_response_id: previous_response_id)

    # For synchronous (non-streaming) responses, handle function requests if not already handled by streamer
    unless response_handled
      if response && response.function_requests.any?
        handle_follow_up_response(response, depth: 0)
      elsif response
        emit(:response, { id: response.id })
      end
    end
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def handle_follow_up_response(response, depth: 0)
      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)

      emit(:response, {
        id: response.id,
        function_tool_calls: function_tool_calls
      })

      # Get follow-up response with tool call results
      follow_up = get_llm_response(
        streamer: nil,
        function_results: function_tool_calls.map(&:to_result),
        previous_response_id: response.id
      )

      return unless follow_up

      # Emit any text content from the follow-up
      follow_up.messages.each do |msg|
        emit(:output_text, msg.output_text) if msg.output_text.present?
      end

      # If the follow-up also has function requests, handle them recursively (up to MAX_FOLLOW_UP_DEPTH)
      if follow_up.function_requests.any? && depth < MAX_FOLLOW_UP_DEPTH
        handle_follow_up_response(follow_up, depth: depth + 1)
      elsif follow_up.function_requests.any?
        # Hit max depth but model still wants to call functions.
        # Force a final text response by calling without tools.
        Rails.logger.warn("[Assistant::Responder] Max follow-up depth (#{MAX_FOLLOW_UP_DEPTH}) reached for chat #{chat&.id}. Forcing text-only response.")
        force_final_text_response(follow_up)
      else
        emit(:response, { id: follow_up.id })
      end
    end

    # When the model gets stuck in a function call loop, make one last call
    # without any tool definitions to force it to produce a text answer.
    def force_final_text_response(last_response)
      Rails.logger.warn("[Assistant::Responder] Forcing text-only response for chat #{chat&.id}")
      final = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: [],
        function_results: [],
        streamer: nil,
        previous_response_id: last_response.id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      if final.success? && final.data
        final.data.messages.each do |msg|
          emit(:output_text, msg.output_text) if msg.output_text.present?
        end
        emit(:response, { id: final.data.id })
      else
        Rails.logger.warn("[Assistant::Responder] Force text fallback failed for chat #{chat&.id}. Using last response as final.")
        emit(:response, { id: last_response.id })
      end
    end

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
end
