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

  test "final round requests forbid tool calls via tool_choice while keeping tool definitions" do
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
    tool_choices_seen = []

    @llm.stubs(:chat_response).with do |_prompt, **kwargs|
      functions_seen << kwargs[:functions]
      tool_choices_seen << kwargs[:tool_choice]
      true
    end.returns(
      provider_success_response(tool_response),
      provider_success_response(tool_response),
      provider_success_response(text_response)
    )

    with_iteration_cap(2) do
      @responder.respond
    end

    # Every request carries the real tool definitions — Anthropic rejects
    # messages containing tool blocks when no tools are defined — and only the
    # request after the final permitted round forbids further calls.
    assert_operator functions_seen.size, :>=, 2
    assert functions_seen.last.present?
    assert_equal functions_seen.first, functions_seen.last
    assert_equal :none, tool_choices_seen.last
    assert tool_choices_seen[0..-2].all?(&:nil?)
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
