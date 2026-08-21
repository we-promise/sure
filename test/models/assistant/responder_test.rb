require "test_helper"

class Assistant::ResponderTest < ActiveSupport::TestCase
  include ProviderTestHelper

  class EchoFunction < Assistant::Function
    def self.name = "echo"
    def self.description = "Echoes the received arguments"
    def call(params = {}) = params
  end

  setup do
    @chat = chats(:two)
    @message = @chat.messages.create!(
      type: "UserMessage",
      content: "What is my net worth?",
      ai_model: "gpt-4.1"
    )
    @llm = mock
    @llm.stubs(:supports_responses_endpoint?).returns(true)
    @responder = Assistant::Responder.new(
      message: @message,
      instructions: "instructions",
      function_tool_caller: Assistant::FunctionToolCaller.new([ EchoFunction.new(nil) ]),
      llm: @llm
    )
  end

  test "default iteration cap is eight rounds" do
    assert_equal 8, Assistant::Responder::DEFAULT_MAX_TOOL_CALL_ITERATIONS
  end

  test "a model that never stops calling tools hits the cap and raises" do
    function_request = Provider::LlmConcept::ChatFunctionRequest.new(
      id: "1", call_id: "1", function_name: "echo", function_args: "{}"
    )
    tool_response = Provider::LlmConcept::ChatResponse.new(
      id: "1", model: "gpt-4.1", messages: [], function_requests: [ function_request ]
    )

    @llm.stubs(:chat_response).returns(provider_success_response(tool_response))

    with_iteration_cap(2) do
      assert_raises(Assistant::Responder::ToolCallLimitError) { @responder.respond }
    end
  end

  private
    def with_iteration_cap(value)
      previous = ENV["ASSISTANT_MAX_TOOL_CALL_ITERATIONS"]
      ENV["ASSISTANT_MAX_TOOL_CALL_ITERATIONS"] = value.to_s
      yield
    ensure
      ENV["ASSISTANT_MAX_TOOL_CALL_ITERATIONS"] = previous
    end
end
