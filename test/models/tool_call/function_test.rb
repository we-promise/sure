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
end
