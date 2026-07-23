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
end
