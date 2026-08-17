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

  test "final round requests carry no tools so the model must answer in text" do
    function_request = Provider::LlmConcept::ChatFunctionRequest.new(
      id: "1", call_id: "1", function_name: "echo", function_args: "{}"
    )
    tool_response = Provider::LlmConcept::ChatResponse.new(
      id: "1", model: "gpt-4.1", messages: [], function_requests: [ function_request ]
    )
    text_response = Provider::LlmConcept::ChatResponse.new(
      id: "2", model: "gpt-4.1",
      messages: [ Provider::LlmConcept::ChatMessage.new(id: "2", output_text: "Here is what I found") ],
      function_requests: []
    )

    functions_seen = []

    @llm.stubs(:chat_response).with do |_prompt, **kwargs|
      functions_seen << kwargs[:functions]
      true
    end.returns(
      provider_success_response(tool_response),
      provider_success_response(tool_response),
      provider_success_response(text_response)
    )

    with_iteration_cap(2) do
      @responder.respond
    end

    # First request offers tools; the request after the final permitted round
    # must offer none.
    assert_operator functions_seen.size, :>=, 2
    assert_equal [], functions_seen.last
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
