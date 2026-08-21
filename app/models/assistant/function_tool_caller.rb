class Assistant::FunctionToolCaller
  Error = Class.new(StandardError)
  FunctionExecutionError = Class.new(Error)

  attr_reader :functions

  def initialize(functions = [])
    @functions = functions
  end

  def fulfill_requests(function_requests)
    function_requests.map do |function_request|
      result = execute(function_request)

      ToolCall::Function.from_function_request(function_request, result)
    end
  end

  def function_definitions
    functions.map(&:to_definition)
  end

  private
    # Tool failures come back as data instead of raising, so one bad call no
    # longer aborts the whole turn. The hint steers the model toward a single
    # corrected retry (the system prompt pairs it with a retry-once rule).
    def execute(function_request)
      fn = find_function(function_request)

      if fn.nil?
        return {
          error: "Unknown tool: #{function_request.function_name}",
          hint: "Only call tools from the provided list."
        }
      end

      fn_args = JSON.parse(function_request.function_args.presence || "{}")
      fn.call(fn_args)
    rescue JSON::ParserError
      {
        error: "Arguments were not valid JSON",
        hint: "Re-send #{function_request.function_name} with valid JSON arguments."
      }
    rescue ActiveRecord::RecordNotFound => e
      {
        error: e.message,
        hint: "That record was not found. List valid options first (for example get_accounts or get_categories) and retry once with an exact match."
      }
    rescue Date::Error, ArgumentError, KeyError => e
      {
        error: e.message,
        hint: "Check argument formats (dates are YYYY-MM-DD) and retry once with corrected arguments."
      }
    rescue => e
      Rails.logger.error("Assistant tool #{fn.name} failed: #{e.class}: #{e.message}")

      {
        error: "#{fn.name} failed unexpectedly",
        hint: "Do not retry with the same arguments. Answer with the data you already have and note the gap."
      }
    end

    def find_function(function_request)
      functions.find { |f| f.name == function_request.function_name }
    end
end
