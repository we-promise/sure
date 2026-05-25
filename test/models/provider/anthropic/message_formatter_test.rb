require "test_helper"

class Provider::Anthropic::MessageFormatterTest < ActiveSupport::TestCase
  test "builds a single user turn from prompt alone" do
    formatter = Provider::Anthropic::MessageFormatter.new(prompt: "hi")

    messages = formatter.build

    assert_equal 1, messages.size
    assert_equal({ role: "user", content: "hi" }, messages.first)
  end

  test "skips empty content from history" do
    history = [ stub_user_message("") ]

    messages = Provider::Anthropic::MessageFormatter.new(prompt: "next", conversation_history: history).build

    assert_equal [ { role: "user", content: "next" } ], messages
  end

  test "renders text-only assistant history with no tool calls" do
    history = [
      stub_user_message("first question"),
      stub_assistant_message("first answer")
    ]

    messages = Provider::Anthropic::MessageFormatter.new(prompt: "second question", conversation_history: history).build

    assert_equal({ role: "user", content: "first question" }, messages[0])
    assert_equal "assistant", messages[1][:role]
    assert_equal [ { type: "text", text: "first answer" } ], messages[1][:content]
    assert_equal({ role: "user", content: "second question" }, messages[2])
  end

  test "renders assistant tool_call history with paired tool_result turn" do
    tool_call = stub_tool_call(
      id: "toolu_1",
      name: "get_net_worth",
      arguments: { "currency" => "USD" },
      result: { "amount" => 12345, "currency" => "USD" }
    )
    assistant = stub_assistant_message("Your net worth is $12,345.", tool_calls: [ tool_call ])
    history = [ stub_user_message("net worth?"), assistant ]

    messages = Provider::Anthropic::MessageFormatter.new(prompt: "anything else?", conversation_history: history).build

    assert_equal({ role: "user", content: "net worth?" }, messages[0])
    assert_equal "assistant", messages[1][:role]
    assert_equal "tool_use", messages[1][:content].first[:type]
    assert_equal "toolu_1", messages[1][:content].first[:id]
    assert_equal "get_net_worth", messages[1][:content].first[:name]
    assert_equal({ "currency" => "USD" }, messages[1][:content].first[:input])
    assert_equal "text", messages[1][:content].last[:type]

    assert_equal "user", messages[2][:role]
    assert_equal "tool_result", messages[2][:content].first[:type]
    assert_equal "toolu_1", messages[2][:content].first[:tool_use_id]
    assert_equal({ "amount" => 12345, "currency" => "USD" }.to_json, messages[2][:content].first[:content])

    assert_equal({ role: "user", content: "anything else?" }, messages[3])
  end

  test "renders in-flight function_results as assistant tool_use + user tool_result" do
    formatter = Provider::Anthropic::MessageFormatter.new(
      prompt: "what is my net worth?",
      function_results: [ {
        call_id: "toolu_42",
        name: "get_net_worth",
        arguments: { "currency" => "USD" }.to_json,
        output: { amount: 99, currency: "USD" }
      } ]
    )

    messages = formatter.build

    assert_equal({ role: "user", content: "what is my net worth?" }, messages[0])
    assert_equal "assistant", messages[1][:role]
    assert_equal "tool_use", messages[1][:content].first[:type]
    assert_equal "toolu_42", messages[1][:content].first[:id]
    assert_equal({ "currency" => "USD" }, messages[1][:content].first[:input])

    assert_equal "user", messages[2][:role]
    assert_equal "tool_result", messages[2][:content].first[:type]
    assert_equal "toolu_42", messages[2][:content].first[:tool_use_id]
    assert_includes messages[2][:content].first[:content], "99"
  end

  test "parses string arguments and nil outputs gracefully" do
    formatter = Provider::Anthropic::MessageFormatter.new(
      prompt: "go",
      function_results: [ {
        call_id: "toolu_x",
        name: "noop",
        arguments: "",
        output: nil
      } ]
    )

    messages = formatter.build

    assert_equal({}, messages[1][:content].first[:input])
    assert_equal "", messages[2][:content].first[:content]
  end

  private
    def stub_user_message(content)
      msg = UserMessage.new(content: content, ai_model: "claude-sonnet-4-6")
      msg.id = SecureRandom.uuid
      msg
    end

    def stub_assistant_message(content, tool_calls: [])
      msg = AssistantMessage.new(content: content, ai_model: "claude-sonnet-4-6")
      msg.id = SecureRandom.uuid
      msg.stubs(:tool_calls).returns(tool_calls)
      msg
    end

    def stub_tool_call(id:, name:, arguments:, result:)
      tc = ToolCall::Function.new(
        function_name: name,
        function_arguments: arguments,
        function_result: result
      )
      tc.stubs(:provider_call_id).returns(id)
      tc.stubs(:provider_id).returns(id)
      tc
    end
end
