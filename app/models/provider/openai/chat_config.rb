class Provider::Openai::ChatConfig
  def initialize(functions: [], function_results: [])
    @functions = functions
    @function_results = function_results
  end

  def tools
    functions.map do |fn|
      {
        type: "function",
        name: fn[:name],
        description: fn[:description],
        parameters: fn[:params_schema],
        strict: fn[:strict]
      }
    end
  end

  def build_input(prompt)
    results = function_results.map do |fn_result|
      # Handle nil explicitly to avoid serializing to "null"
      output = fn_result[:output]
      serialized_output = if output.nil?
        ""
      elsif output.is_a?(String)
        output
      else
        output.to_json
      end

      {
        type: "function_call_output",
        call_id: fn_result[:call_id],
        output: serialized_output
      }
    end

    [
      { role: "user", content: prompt },
      *results
    ]
  end

  private
    attr_reader :functions, :function_results
end
