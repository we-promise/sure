require "test_helper"
require "ostruct"

class Provider::Anthropic::ChatParserTest < ActiveSupport::TestCase
  test "parses text-only message into ChatResponse with single output_text" do
    raw = build_message(
      id: "msg_1",
      model: "claude-sonnet-4-6",
      content: [
        OpenStruct.new(type: :text, text: "Hello"),
        OpenStruct.new(type: :text, text: "world")
      ]
    )

    parsed = Provider::Anthropic::ChatParser.new(raw).parsed

    assert_equal "msg_1", parsed.id
    assert_equal "claude-sonnet-4-6", parsed.model
    assert_equal 1, parsed.messages.size
    assert_equal "Hello\nworld", parsed.messages.first.output_text
    assert_empty parsed.function_requests
  end

  test "parses tool_use blocks into ChatFunctionRequest" do
    raw = build_message(
      id: "msg_2",
      model: "claude-sonnet-4-6",
      content: [
        OpenStruct.new(
          type: :tool_use,
          id: "toolu_abc",
          name: "get_transactions",
          input: { "page" => 1, "order" => "asc" }
        )
      ]
    )

    parsed = Provider::Anthropic::ChatParser.new(raw).parsed

    assert_empty parsed.messages
    assert_equal 1, parsed.function_requests.size
    req = parsed.function_requests.first
    assert_equal "toolu_abc", req.id
    assert_equal "toolu_abc", req.call_id
    assert_equal "get_transactions", req.function_name
    assert_equal({ "page" => 1, "order" => "asc" }.to_json, req.function_args)
  end

  test "parses mixed content blocks" do
    raw = build_message(
      id: "msg_3",
      model: "claude-sonnet-4-6",
      content: [
        OpenStruct.new(type: :text, text: "Looking up your transactions..."),
        OpenStruct.new(type: :tool_use, id: "toolu_42", name: "get_transactions", input: {})
      ]
    )

    parsed = Provider::Anthropic::ChatParser.new(raw).parsed

    assert_equal 1, parsed.messages.size
    assert_equal "Looking up your transactions...", parsed.messages.first.output_text
    assert_equal 1, parsed.function_requests.size
    assert_equal "toolu_42", parsed.function_requests.first.call_id
  end

  test "normalizes empty-string tool input to an empty JSON object" do
    raw = build_message(
      id: "msg_5",
      model: "claude-sonnet-4-6",
      content: [
        OpenStruct.new(type: :tool_use, id: "toolu_noargs", name: "get_categories", input: "")
      ]
    )

    parsed = Provider::Anthropic::ChatParser.new(raw).parsed

    req = parsed.function_requests.first
    assert_equal "{}", req.function_args
    # Must survive the downstream JSON.parse that fulfills the tool call.
    assert_equal({}, JSON.parse(req.function_args))
  end

  test "normalizes nil tool input to an empty JSON object" do
    raw = build_message(
      id: "msg_6",
      model: "claude-sonnet-4-6",
      content: [
        OpenStruct.new(type: :tool_use, id: "toolu_nil", name: "get_categories", input: nil)
      ]
    )

    parsed = Provider::Anthropic::ChatParser.new(raw).parsed

    assert_equal "{}", parsed.function_requests.first.function_args
  end

  test "accepts hash-shaped content blocks" do
    raw = OpenStruct.new(
      id: "msg_4",
      model: "claude-sonnet-4-6",
      content: [
        { type: :text, text: "from hash" }
      ]
    )

    parsed = Provider::Anthropic::ChatParser.new(raw).parsed

    assert_equal "from hash", parsed.messages.first.output_text
  end

  private
    def build_message(id:, model:, content:)
      OpenStruct.new(id: id, model: model, content: content)
    end
end
