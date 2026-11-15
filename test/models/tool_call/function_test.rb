require "test_helper"

class ToolCall::FunctionTest < ActiveSupport::TestCase
  test "to_tool_call serializes object arguments to a JSON string" do
    tool_call = ToolCall::Function.new(
      provider_id: "resp_1",
      provider_call_id: "call_1",
      function_name: "get_net_worth",
      function_arguments: { "currency" => "USD" },
      function_result: { "amount" => 10000 }
    )

    arguments = tool_call.to_tool_call.dig(:function, :arguments)

    assert_instance_of String, arguments
    assert_equal({ "currency" => "USD" }, JSON.parse(arguments))
  end

  test "to_tool_call leaves string arguments untouched" do
    tool_call = ToolCall::Function.new(
      provider_id: "resp_1",
      provider_call_id: "call_1",
      function_name: "get_net_worth",
      function_arguments: '{"currency":"USD"}',
      function_result: { "amount" => 10000 }
    )

    assert_equal '{"currency":"USD"}', tool_call.to_tool_call.dig(:function, :arguments)
  end

  test "to_tool_call normalizes blank arguments to an empty JSON object" do
    [ "", "   ", nil ].each do |blank_args|
      tool_call = ToolCall::Function.new(
        provider_id: "resp_1",
        provider_call_id: "call_1",
        function_name: "get_net_worth",
        function_arguments: blank_args,
        function_result: { "amount" => 10000 }
      )

      assert_equal "{}", tool_call.to_tool_call.dig(:function, :arguments), "expected #{blank_args.inspect} to serialize as \"{}\""
    end
  end

  test "to_result keeps arguments as stored (object or string)" do
    tool_call = ToolCall::Function.new(
      provider_id: "resp_1",
      provider_call_id: "call_1",
      function_name: "get_net_worth",
      function_arguments: { "currency" => "USD" },
      function_result: { "amount" => 10000 }
    )

    assert_equal({ "currency" => "USD" }, tool_call.to_result[:arguments])
  end

  test "to_tool_call sorts object argument keys so replayed bytes match the in-flight ones" do
    in_flight = ToolCall::Function.new(
      provider_id: "resp_1",
      provider_call_id: "call_1",
      function_name: "get_transactions",
      function_arguments: { "bb" => 1, "a" => { "y" => 2, "x" => 3 } },
      function_result: { "page" => 1 }
    )
    stored = ToolCall::Function.create!(
      message: messages(:chat1_assistant_response),
      provider_id: "resp_1",
      provider_call_id: "call_1",
      function_name: "get_transactions",
      function_arguments: { "bb" => 1, "a" => { "y" => 2, "x" => 3 } },
      function_result: { "page" => 1 }
    )

    expected = '{"a":{"x":3,"y":2},"bb":1}'
    assert_equal expected, in_flight.to_tool_call.dig(:function, :arguments)
    assert_equal expected, ToolCall::Function.find(stored.id).to_tool_call.dig(:function, :arguments)
  end

  test "from_function_request preserves extra_content and includes it in to_result and to_tool_call" do
    extra = { "google" => { "thought_signature" => "sig_123" } }
    request = Provider::LlmConcept::ChatFunctionRequest.new(
      id: "resp_1",
      call_id: "call_1",
      function_name: "get_net_worth",
      function_args: '{"currency":"USD"}',
      extra_content: extra
    )

    tool_call = ToolCall::Function.from_function_request(request, { "amount" => 10000 })

    assert_equal extra, tool_call.extra_content
    assert_equal extra, tool_call.to_result[:extra_content]
    assert_equal extra, tool_call.to_tool_call[:extra_content]
  end

  test "to_tool_call omits extra_content when not set" do
    tool_call = ToolCall::Function.new(
      provider_id: "resp_1",
      provider_call_id: "call_1",
      function_name: "get_net_worth",
      function_arguments: '{"currency":"USD"}',
      function_result: { "amount" => 10000 }
    )

    assert_nil tool_call.extra_content
    assert_not_includes tool_call.to_tool_call.keys, :extra_content
  end

  test "extra_content is persisted in the database and reloaded across turns" do
    extra = { "google" => { "thought_signature" => "sig_persisted_123" } }
    message = messages(:chat1_assistant_response)

    tool_call = ToolCall::Function.create!(
      message: message,
      provider_id: "resp_1",
      provider_call_id: "call_1",
      function_name: "get_net_worth",
      function_arguments: '{"currency":"USD"}',
      function_result: { "amount" => 10000 },
      extra_content: extra
    )

    reloaded = ToolCall::Function.find(tool_call.id)
    assert_equal extra, reloaded.extra_content
    assert_equal extra, reloaded.to_tool_call[:extra_content]
    assert_equal extra, reloaded.to_result[:extra_content]
  end

  test "serialize_output sorts object keys at every depth and leaves arrays in order" do
    output = { "b" => 1, "a" => { "z" => 1, "y" => [ { "d" => 1, "c" => 2 }, 3 ] } }

    assert_equal '{"a":{"y":[{"c":2,"d":1},3],"z":1},"b":1}', ToolCall::Function.serialize_output(output)
  end

  test "serialize_output passes strings through and renders nil as empty" do
    assert_equal "plain", ToolCall::Function.serialize_output("plain")
    assert_equal "", ToolCall::Function.serialize_output(nil)
  end

  test "serialize_output is identical before and after a jsonb reload" do
    result = { "transactions" => [ { "name" => "Rent", "amount" => 100 } ], "total_results" => 1, "page" => 1 }
    tool_call = ToolCall::Function.create!(
      message: messages(:chat1_assistant_response),
      provider_id: "call_1",
      provider_call_id: "call_1",
      function_name: "get_transactions",
      function_arguments: "{}",
      function_result: result,
      round: 1
    )

    reloaded = ToolCall::Function.find(tool_call.id)

    assert_equal(
      ToolCall::Function.serialize_output(tool_call.function_result),
      ToolCall::Function.serialize_output(reloaded.function_result)
    )
    assert_equal 1, reloaded.to_result[:round]
  end
end
