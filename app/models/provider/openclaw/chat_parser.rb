class Provider::Openclaw::ChatParser
  Error = Class.new(StandardError)

  def initialize(object)
    @object = object
  end

  def parsed
    ChatResponse.new(
      id: response_id,
      model: response_model,
      messages: messages,
      function_requests: function_requests
    )
  end

  private
    attr_reader :object

    ChatResponse = Provider::LlmConcept::ChatResponse
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatFunctionRequest = Provider::LlmConcept::ChatFunctionRequest

    def response_id
      object["id"] || SecureRandom.uuid
    end

    def response_model
      object["model"] || "openclaw"
    end

    def messages
      content = extract_content
      return [] if content.blank?

      [
        ChatMessage.new(
          id: response_id,
          output_text: content
        )
      ]
    end

    def extract_content
      # OpenClaw may return content in different formats
      object["content"] ||
        object["text"] ||
        object["message"] ||
        object.dig("response", "content") ||
        object.dig("choices", 0, "message", "content")
    end

    def function_requests
      tool_calls = extract_tool_calls
      return [] if tool_calls.blank?

      tool_calls.map do |tool_call|
        ChatFunctionRequest.new(
          id: tool_call["id"] || SecureRandom.uuid,
          call_id: tool_call["id"] || tool_call["call_id"] || SecureRandom.uuid,
          function_name: tool_call.dig("function", "name") || tool_call["name"],
          function_args: extract_function_args(tool_call)
        )
      end
    end

    def extract_tool_calls
      object["tool_calls"] ||
        object.dig("response", "tool_calls") ||
        object.dig("choices", 0, "message", "tool_calls") ||
        []
    end

    def extract_function_args(tool_call)
      args = tool_call.dig("function", "arguments") || tool_call["arguments"]
      args.is_a?(String) ? args : args.to_json
    end
end
