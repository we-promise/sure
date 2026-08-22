require "test_helper"

class Assistant::FunctionToolCallerTest < ActiveSupport::TestCase
  # Minimal stub function that echoes back whatever args it receives.
  class EchoFunction < Assistant::Function
    def self.name = "echo"
    def self.description = "Echoes the received arguments"
    def call(params = {}) = params
  end

  FunctionRequest = Provider::LlmConcept::ChatFunctionRequest

  setup do
    @caller = Assistant::FunctionToolCaller.new([ EchoFunction.new(nil) ])
  end

  test "parses JSON arguments and forwards them to the function" do
    request = FunctionRequest.new(
      id: "call_1", call_id: "call_1", function_name: "echo",
      function_args: { "foo" => "bar" }.to_json
    )

    result = @caller.fulfill_requests([ request ]).first

    assert_equal({ "foo" => "bar" }, result.function_result)
  end

  test "treats empty-string arguments as an empty argument set" do
    request = FunctionRequest.new(
      id: "call_2", call_id: "call_2", function_name: "echo",
      function_args: ""
    )

    # Regression for #2722: JSON.parse("") used to raise, killing the turn.
    result = assert_nothing_raised do
      @caller.fulfill_requests([ request ]).first
    end

    assert_equal({}, result.function_result)
  end

  test "treats nil arguments as an empty argument set" do
    request = FunctionRequest.new(
      id: "call_3", call_id: "call_3", function_name: "echo",
      function_args: nil
    )

    result = assert_nothing_raised do
      @caller.fulfill_requests([ request ]).first
    end

    assert_equal({}, result.function_result)
  end

  test "unknown tool returns an error result instead of raising" do
    request = FunctionRequest.new(
      id: "call_4", call_id: "call_4", function_name: "does_not_exist",
      function_args: "{}"
    )

    result = assert_nothing_raised do
      @caller.fulfill_requests([ request ]).first
    end

    assert_equal "Unknown tool: does_not_exist", result.function_result["error"]
    assert_includes result.function_result["hint"], "provided list"
  end

  test "invalid JSON arguments return an error result with a hint" do
    request = FunctionRequest.new(
      id: "call_5", call_id: "call_5", function_name: "echo",
      function_args: "{not json"
    )

    result = @caller.fulfill_requests([ request ]).first

    assert_equal "Arguments were not valid JSON", result.function_result["error"]
    assert_includes result.function_result["hint"], "echo"
  end

  test "missing records return an error result steering a corrected retry" do
    caller = Assistant::FunctionToolCaller.new([ NotFoundFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_6", call_id: "call_6", function_name: "not_found",
      function_args: "{}"
    )

    result = caller.fulfill_requests([ request ]).first

    assert_includes result.function_result["hint"], "retry once"
  end

  test "date and argument errors return an error result with a format hint" do
    caller = Assistant::FunctionToolCaller.new([ BadDateFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_7", call_id: "call_7", function_name: "bad_date",
      function_args: "{}"
    )

    result = caller.fulfill_requests([ request ]).first

    assert_includes result.function_result["hint"], "YYYY-MM-DD"
  end

  test "unexpected failures return a do-not-retry error result" do
    caller = Assistant::FunctionToolCaller.new([ ExplodingFunction.new(nil) ])
    request = FunctionRequest.new(
      id: "call_8", call_id: "call_8", function_name: "exploding",
      function_args: "{}"
    )

    result = assert_nothing_raised do
      caller.fulfill_requests([ request ]).first
    end

    assert_equal "exploding failed unexpectedly", result.function_result["error"]
    assert_includes result.function_result["hint"], "Do not retry"
  end

  class NotFoundFunction < Assistant::Function
    def self.name = "not_found"
    def self.description = "Always raises RecordNotFound"
    def call(params = {}) = raise(ActiveRecord::RecordNotFound, "Couldn't find Account")
  end

  class BadDateFunction < Assistant::Function
    def self.name = "bad_date"
    def self.description = "Always raises a date parse error"
    def call(params = {}) = Date.parse("not-a-date")
  end

  class ExplodingFunction < Assistant::Function
    def self.name = "exploding"
    def self.description = "Always raises an unexpected error"
    def call(params = {}) = raise(NoMethodError, "boom")
  end
end
