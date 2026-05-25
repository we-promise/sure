class Provider::Anthropic::MessageFormatter
  # Builds the `messages` array Anthropic expects.
  #
  # Inputs:
  # - prompt: text of the current user turn
  # - conversation_history: chronologically-ordered Message records preceding
  #   the current user message (UserMessage / AssistantMessage)
  # - function_results: tool-result entries for the in-flight follow-up call
  #   (the responder feeds these back after executing the tool_use blocks
  #   returned by the previous request)
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

    if @function_results.present?
      tool_use_blocks = @function_results.map { |fr| tool_use_block_from_result(fr) }
      tool_result_blocks = @function_results.map { |fr| tool_result_block(fr) }

      messages << { role: "assistant", content: tool_use_blocks }
      messages << { role: "user", content: tool_result_blocks }
    end

    messages
  end

  private
    def assistant_history_blocks(assistant_message)
      blocks = []
      blocks.concat(assistant_message.tool_calls.map { |tc| tool_use_block_from_record(tc) }) if assistant_message.tool_calls.any?
      blocks << { type: "text", text: assistant_message.content.to_s } if assistant_message.content.present?

      return [] if blocks.empty?

      result = [ { role: "assistant", content: blocks } ]

      # If the assistant turn used tools, Anthropic requires a user turn with
      # matching tool_result blocks before the next assistant turn.
      if assistant_message.tool_calls.any?
        result << {
          role: "user",
          content: assistant_message.tool_calls.map { |tc| tool_result_block_from_record(tc) }
        }
      end

      result
    end

    def tool_use_block_from_record(tool_call)
      {
        type: "tool_use",
        id: tool_call.provider_call_id || tool_call.provider_id,
        name: tool_call.function_name,
        input: parse_arguments(tool_call.function_arguments)
      }
    end

    def tool_result_block_from_record(tool_call)
      {
        type: "tool_result",
        tool_use_id: tool_call.provider_call_id || tool_call.provider_id,
        content: serialize_output(tool_call.function_result)
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
        content: serialize_output(function_result[:output])
      }
    end

    def parse_arguments(arguments)
      case arguments
      when nil then {}
      when Hash then arguments
      when String
        return {} if arguments.blank?
        JSON.parse(arguments)
      else arguments
      end
    rescue JSON::ParserError
      {}
    end

    def serialize_output(output)
      case output
      when nil then ""
      when String then output
      else output.to_json
      end
    end
end
