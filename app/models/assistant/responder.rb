class Assistant::Responder
  ToolCallLimitError = Class.new(StandardError)
  EmptyResponseError = Class.new(StandardError)
  # Rounds, not calls: parallel calls in one round count once. Eight covers a
  # taxonomy lookup, a target lookup, an action, one hint-corrected retry, a
  # verification read and a summary, with margin. Override with
  # ASSISTANT_MAX_TOOL_CALL_ITERATIONS (low-resource hosts may want 2).
  DEFAULT_MAX_TOOL_CALL_ITERATIONS = 8

  # Splits in-flight function results into tool rounds, in order. #respond
  # tags each result with the :round that produced it; providers that rebuild
  # the in-flight history replay one tool-call message plus its results per
  # round, so every follow-up request extends the previous one instead of
  # rewriting it. Results without a :round tag form a single round.
  def self.group_by_round(function_results)
    function_results.chunk_while { |a, b| a[:round] == b[:round] }.to_a
  end

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
    response, response_has_text = request_response(**opening_request(previous_response_id))
    any_response_has_text = response_has_text
    in_flight_function_results = []
    iteration = 0

    while response.function_requests.any?
      iteration += 1
      if iteration > max_tool_call_iterations
        raise ToolCallLimitError,
              "Assistant exceeded the tool-call limit of #{max_tool_call_iterations} for one response"
      end

      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)
      # Stored with the calls, so a reply that fails before its follow-up
      # knows which response is waiting for their results.
      function_tool_calls.each { |tool_call| tool_call.provider_response_id = response.id }
      function_results = function_tool_calls.map(&:to_result)
      # Tag each result with its round; see .group_by_round.
      in_flight_function_results.concat(function_results.map { |result| result.merge(round: iteration) })

      emit(:response, {
        id: response.id,
        function_tool_calls: function_tool_calls
      })

      # On the final permitted round the follow-up request forbids further
      # tool calls via tool_choice, so the model must answer in text with
      # whatever it has gathered instead of the turn dying in
      # ToolCallLimitError. The real tool definitions stay in the request —
      # Anthropic rejects messages containing tool blocks when no tools are
      # defined, so dropping the tool list is not an option.
      final_round = iteration == max_tool_call_iterations

      response, response_has_text = request_response(
        function_results: provider_preserves_response_context? ? function_results : in_flight_function_results.dup,
        previous_response_id: response.id,
        tool_choice: final_round ? :none : nil
      )
      any_response_has_text ||= response_has_text
    end

    raise EmptyResponseError, "Assistant returned neither text nor tool calls" unless any_response_has_text

    emit(:response, { id: response.id })
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def request_response(function_results: [], previous_response_id: nil, tool_choice: nil, prompt: message.content)
      response_has_text = false

      leading_whitespace = +""

      streamer = proc do |chunk|
        # A whitespace-only chunk is real text (OpenAI streams the space before a number as its own chunk),
        # but a message cannot be saved with whitespace-only content, so hold leading whitespace back
        # until the first non-blank chunk arrives and emit it together with that chunk.
        if chunk.type == "output_text" && !chunk.data.to_s.empty?
          if response_has_text
            emit(:output_text, chunk.data)
          elsif chunk.data.blank?
            leading_whitespace << chunk.data
          else
            response_has_text = true
            emit(:output_text, leading_whitespace + chunk.data)
            leading_whitespace = +""
          end
        end
      end

      response = get_llm_response(
        prompt: prompt,
        streamer: streamer,
        function_results: function_results,
        previous_response_id: previous_response_id,
        tool_choice: tool_choice
      )

      response_has_text ||= response.messages.any? { |response_message| response_message.output_text.present? }
      [ response, response_has_text ]
    end

    # Stateless providers get the stored conversation every time, executed
    # tool calls included (see #history_messages). The Responses API keeps
    # the conversation server-side, and never got the results of tools run
    # by the latest reply if it then failed: continue from the response that
    # asked for them and hand them over, followed by the prompt unless the
    # chain already has it (a Retry asks again for the same prompt).
    def opening_request(previous_response_id)
      unanswered_reply = latest_reply if provider_preserves_response_context?
      unanswered_calls = unanswered_reply&.unanswered_tool_calls || []
      return { previous_response_id: previous_response_id } if unanswered_calls.empty?

      {
        previous_response_id: unanswered_calls.first.provider_response_id,
        function_results: unanswered_calls.map(&:to_result),
        prompt: (message.content if message.created_at > unanswered_reply.created_at)
      }
    end

    def latest_reply
      history_messages.reverse.find { |history_message| history_message.is_a?(AssistantMessage) }
    end

    def provider_preserves_response_context?
      llm.respond_to?(:supports_responses_endpoint?) && llm.supports_responses_endpoint?
    end

    def max_tool_call_iterations
      configured = Integer(ENV.fetch("ASSISTANT_MAX_TOOL_CALL_ITERATIONS", DEFAULT_MAX_TOOL_CALL_ITERATIONS).to_s, 10)
      configured.positive? ? configured : DEFAULT_MAX_TOOL_CALL_ITERATIONS
    rescue ArgumentError
      DEFAULT_MAX_TOOL_CALL_ITERATIONS
    end

    def get_llm_response(prompt:, streamer:, function_results: [], previous_response_id: nil, tool_choice: nil)
      Usage.capture("ai_assistant_served_daily")
      response = llm.chat_response(
        prompt,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        tool_choice: tool_choice,
        messages: openai_messages_payload,
        conversation_history: history_messages,
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

    # The stored conversation every provider request replays, in order and
    # including the current prompt. Only the reply being generated (pending)
    # is left out; its tool rounds travel as in-flight function_results.
    # Failed replies stay in: the tools they ran happened, and a model that
    # does not see them would run them again. Their partial text does not
    # (Message#replayed_content). Memoized so a turn fires one history query.
    def history_messages
      @history_messages ||=
        if chat&.messages
          chat.messages
              .where(type: [ "UserMessage", "AssistantMessage" ], status: [ "complete", "failed" ])
              .includes(:tool_calls)
              .ordered
              .to_a
        else
          []
        end
    end

    # Builds the OpenAI-shaped messages payload (role: "user" | "assistant" |
    # "tool"; tool_call_id pairing) consumed by Provider::Openai's generic
    # chat path. Anthropic renders history_messages itself.
    def openai_messages_payload
      messages = []
      history_messages.each do |chat_message|
        if chat_message.tool_calls.any?
          messages << {
            role: chat_message.role,
            content: chat_message.replayed_content,
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
              content: content
            }
          end

        elsif chat_message.replayed_content.present?
          messages << { role: chat_message.role, content: chat_message.replayed_content }
        end
      end
      messages
    end
end
