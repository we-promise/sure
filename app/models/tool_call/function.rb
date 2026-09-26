class ToolCall::Function < ToolCall
  validates :function_name, :function_result, presence: true
  validates :function_arguments, presence: true, allow_blank: true

  class << self
    # Translates an "LLM Concept" provider's FunctionRequest into a ToolCall::Function
    def from_function_request(function_request, result)
      new(
        provider_id: function_request.id,
        provider_call_id: function_request.call_id,
        function_name: function_request.function_name,
        function_arguments: function_request.function_args,
        function_result: result
      )
    end

    # Serializes tool-call arguments to the JSON-encoded string OpenAI requires.
    # Blank strings (and nil) become "{}" so zero-argument calls don't send an
    # empty string that strict OpenAI-compatible endpoints reject with a 400.
    def serialize_arguments(args)
      return "{}" if args.nil? || (args.is_a?(String) && args.blank?)

      args.is_a?(String) ? args : args.to_json
    end
  end

  def to_result
    {
      call_id: provider_call_id,
      name: function_name,
      arguments: function_arguments,
      output: function_result
    }
  end

  def to_tool_call
    # OpenAI requires `function.arguments` to be a JSON-encoded string. Some
    # OpenAI-compatible endpoints reject an object payload with a 400.
    arguments = self.class.serialize_arguments(function_arguments)

    {
      id: provider_call_id,
      type: "function",
      function: {
        name: function_name,
        arguments: arguments
      }
    }
  end
end
