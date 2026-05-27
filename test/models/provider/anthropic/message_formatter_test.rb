require "test_helper"
require "ostruct"

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

  # Confirms the round-trip flagged in PR #1983 review: an Anthropic tool_use
  # block returned by the model → ChatFunctionRequest → ToolCall::Function
  # persisted on the AssistantMessage → MessageFormatter rebuild on the next
  # turn produces an Anthropic-compatible history where tool_use_id pairs back
  # to the original block.
  test "ChatParser → ToolCall::Function → MessageFormatter round-trips tool_use_id" do
    anthropic_response = OpenStruct.new(
      id: "msg_abc",
      model: "claude-sonnet-4-6",
      content: [
        OpenStruct.new(type: :tool_use, id: "toolu_round_trip", name: "get_net_worth", input: { "currency" => "USD" })
      ]
    )

    parsed = Provider::Anthropic::ChatParser.new(anthropic_response).parsed
    function_request = parsed.function_requests.first

    persisted_tool_call = ToolCall::Function.from_function_request(
      function_request,
      { "amount" => 12345, "currency" => "USD" }
    )

    assistant = stub_assistant_message("Your net worth is $12,345.", tool_calls: [ persisted_tool_call ])
    history = [ stub_user_message("net worth?"), assistant ]

    rebuilt = Provider::Anthropic::MessageFormatter.new(prompt: "follow-up", conversation_history: history).build

    tool_use_block = rebuilt[1][:content].find { |b| b[:type] == "tool_use" }
    tool_result_block = rebuilt[2][:content].first

    assert_equal "toolu_round_trip", tool_use_block[:id]
    assert_equal "toolu_round_trip", tool_result_block[:tool_use_id]
    assert_equal({ "currency" => "USD" }, tool_use_block[:input])
    assert_equal({ "amount" => 12345, "currency" => "USD" }.to_json, tool_result_block[:content])
  end

  test "renders multi-tool assistant turn with all pairings preserved" do
    tool_a = stub_tool_call(
      id: "toolu_a",
      name: "get_accounts",
      arguments: {},
      result: [ { "id" => 1, "name" => "Checking" } ]
    )
    tool_b = stub_tool_call(
      id: "toolu_b",
      name: "get_holdings",
      arguments: {},
      result: [ { "ticker" => "VTI", "qty" => 10 } ]
    )
    assistant = stub_assistant_message("Looked up your accounts and holdings.", tool_calls: [ tool_a, tool_b ])

    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: "follow-up",
      conversation_history: [ stub_user_message("accounts and holdings?"), assistant ]
    ).build

    tool_uses = messages[1][:content].select { |b| b[:type] == "tool_use" }
    tool_results = messages[2][:content]

    assert_equal 2, tool_uses.size
    assert_equal 2, tool_results.size
    assert_equal [ "toolu_a", "toolu_b" ], tool_uses.map { |b| b[:id] }
    assert_equal [ "toolu_a", "toolu_b" ], tool_results.map { |b| b[:tool_use_id] }
    # Anthropic requires the user turn to follow the assistant turn that used tools
    assert_equal "assistant", messages[1][:role]
    assert_equal "user", messages[2][:role]
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

  # Anthropic's tool_use.input MUST be a JSON object (map). If a stored
  # ToolCall::Function record carries arguments that parse to a scalar or
  # array (corrupt row, legacy data, OpenAI cross-bleed), the formatter
  # must coerce them to `{}` so we don't ship an invalid payload.
  test "coerces non-Hash parsed arguments to empty Hash" do
    [ '"hello"', "123", "true", "[1,2,3]" ].each do |non_object_json|
      formatter = Provider::Anthropic::MessageFormatter.new(
        prompt: "go",
        function_results: [ {
          call_id: "toolu_x",
          name: "noop",
          arguments: non_object_json,
          output: nil
        } ]
      )

      messages = formatter.build

      assert_equal({}, messages[1][:content].first[:input],
        "expected empty Hash for arguments=#{non_object_json.inspect}")
    end
  end

  test "coerces non-Hash non-String arguments to empty Hash" do
    formatter = Provider::Anthropic::MessageFormatter.new(
      prompt: "go",
      function_results: [ {
        call_id: "toolu_x",
        name: "noop",
        arguments: [ 1, 2, 3 ],
        output: nil
      } ]
    )

    messages = formatter.build

    assert_equal({}, messages[1][:content].first[:input])
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
