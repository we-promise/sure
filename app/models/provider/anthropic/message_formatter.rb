class Provider::Anthropic::MessageFormatter
  # Builds the `messages` array Anthropic expects.
  #
  # Inputs:
  # - prompt: text of the current user turn
  # - conversation_history: chronologically-ordered Message records preceding
  #   the current user message (UserMessage / AssistantMessage)
  # - function_results: tool-result entries for the in-flight follow-up call
  #   (the responder feeds these back after executing the tool_use blocks
  #   returned by the previous requests, tagging each with its :round)
  def initialize(prompt:, conversation_history: [], function_results: [])
    @prompt = prompt
    @conversation_history = conversation_history
    @function_results = function_results
  end

  def build
    messages = []

    @conversation_history.each do |historical|
      case historical
      when UserMessage
        messages << { role: "user", content: historical.content.to_s } if historical.content.present?
      when AssistantMessage
        messages.concat(assistant_history_blocks(historical))
      end
    end

    messages << { role: "user", content: @prompt.to_s }

    # One assistant tool_use turn plus its user tool_result turn per round, in
    # order, so each follow-up request extends the previous one and prompt
    # caching keeps working.
    Assistant::Responder.group_by_round(@function_results).each do |round_results|
      messages << { role: "assistant", content: round_results.map { |fr| tool_use_block_from_result(fr) } }
      messages << { role: "user", content: round_results.map { |fr| tool_result_block(fr) } }
    end

    messages
  end

  private
    # One assistant tool_use turn and one user tool_result turn per round, then
    # the final answer as its own assistant turn. #build sends the same shape
    # mid-turn, so a replayed turn is a prefix of its own requests.
    def assistant_history_blocks(assistant_message)
      result = []

      assistant_message.tool_call_rounds.each do |round|
        # tool_use_id is required; skip calls missing both identifiers rather
        # than sending `id: nil` and getting rejected by Anthropic.
        round = round.select { |tc| tool_call_id(tc).present? }
        next if round.empty?

        result << { role: "assistant", content: round.map { |tc| tool_use_block_from_record(tc) } }
        result << { role: "user", content: round.map { |tc| tool_result_block_from_record(tc) } }
      end

      result << { role: "assistant", content: [ { type: "text", text: assistant_message.content.to_s } ] } if assistant_message.content.present?
      result
    end

    def tool_call_id(tool_call)
      tool_call.provider_call_id.presence || tool_call.provider_id.presence
    end

    def tool_use_block_from_record(tool_call)
      {
        type: "tool_use",
        id: tool_call_id(tool_call),
        name: tool_call.function_name,
        input: parse_arguments(tool_call.function_arguments)
      }
    end

    def tool_result_block_from_record(tool_call)
      {
        type: "tool_result",
        tool_use_id: tool_call_id(tool_call),
        content: ToolCall::Function.serialize_output(tool_call.function_result)
      }
    end

    def tool_use_block_from_result(function_result)
      {
        type: "tool_use",
        id: function_result[:call_id],
        name: function_result[:name],
        input: parse_arguments(function_result[:arguments])
      }
    end

    def tool_result_block(function_result)
      {
        type: "tool_result",
        tool_use_id: function_result[:call_id],
        content: ToolCall::Function.serialize_output(function_result[:output])
      }
    end

    # Anthropic's Messages API requires `tool_use.input` to be a JSON object
    # (map). Normalize any non-Hash result to `{}` so corrupt or legacy
    # ToolCall::Function records can't produce a payload Anthropic rejects.
    def parse_arguments(arguments)
      parsed =
        case arguments
        when nil then {}
        when Hash then arguments
        when String
          return {} if arguments.blank?
          JSON.parse(arguments)
        else arguments
        end

      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
end
