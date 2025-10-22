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
    {
      id: provider_call_id,
      type: "function",
      function: {
        name: function_name,
        arguments: function_arguments
      }
    }
  end
end
