require "test_helper"

class Assistant::HistoryTrimmerTest < ActiveSupport::TestCase
  test "returns empty array for empty input" do
    assert_equal [], Assistant::HistoryTrimmer.new([], max_tokens: 1000).call
    assert_equal [], Assistant::HistoryTrimmer.new(nil, max_tokens: 1000).call
  end

  test "returns empty array when max_tokens is zero or negative" do
    messages = [ { role: "user", content: "hi" } ]
    assert_equal [], Assistant::HistoryTrimmer.new(messages, max_tokens: 0).call
    assert_equal [], Assistant::HistoryTrimmer.new(messages, max_tokens: -10).call
  end

  test "keeps full history when budget is generous" do
    messages = [
      { role: "user", content: "a" * 40 },
      { role: "assistant", content: "b" * 40 },
      { role: "user", content: "c" * 40 }
    ]

    result = Assistant::HistoryTrimmer.new(messages, max_tokens: 10_000).call

    assert_equal messages, result
  end

  test "drops oldest messages when budget is tight" do
    messages = [
      { role: "user", content: "a" * 100 },
      { role: "assistant", content: "b" * 100 },
      { role: "user", content: "c" * 100 }
    ]

    # ~40 tokens per message; budget of 60 should keep only the last one
    result = Assistant::HistoryTrimmer.new(messages, max_tokens: 60).call

    assert_equal 1, result.size
    assert_equal "c" * 100, result.first[:content]
  end

  test "keeps tool_call and tool_result as an atomic pair" do
    messages = [
      { role: "user", content: "a" * 40 },
      { role: "assistant", content: "", tool_calls: [ { id: "c1", type: "function", function: { name: "f", arguments: "{}" } } ] },
      { role: "tool", tool_call_id: "c1", name: "f", content: "result" },
      { role: "assistant", content: "follow up" }
    ]

    # Small budget: should keep the newest assistant follow-up. Pair is either
    # kept together or dropped together — never split.
    result = Assistant::HistoryTrimmer.new(messages, max_tokens: 20).call

    tool_call_idx = result.index { |m| m[:role] == "assistant" && m[:tool_calls] }
    tool_result_idx = result.index { |m| m[:role] == "tool" }

    if tool_call_idx
      assert_not_nil tool_result_idx, "tool_call without paired tool_result"
      assert tool_result_idx > tool_call_idx, "tool_result must follow its tool_call"
    else
      assert_nil tool_result_idx, "tool_result without paired tool_call leaked through"
    end
  end

  test "never splits tool_call + tool_result pair when dropping" do
    messages = [
      { role: "assistant", content: "", tool_calls: [ { id: "c1", type: "function", function: { name: "f", arguments: "{}" } } ] },
      { role: "tool", tool_call_id: "c1", name: "f", content: "x" * 200 },
      { role: "user", content: "y" * 20 }
    ]

    # Budget big enough for the user turn, not for the pair
    result = Assistant::HistoryTrimmer.new(messages, max_tokens: 15).call

    assert_equal 1, result.size
    assert_equal "user", result.first[:role]
  end

  test "handles multiple tool results following a single assistant tool_calls message" do
    messages = [
      { role: "user", content: "hi" },
      { role: "assistant", content: "", tool_calls: [
        { id: "c1", type: "function", function: { name: "f1", arguments: "{}" } },
        { id: "c2", type: "function", function: { name: "f2", arguments: "{}" } }
      ] },
      { role: "tool", tool_call_id: "c1", name: "f1", content: "r1" },
      { role: "tool", tool_call_id: "c2", name: "f2", content: "r2" }
    ]

    result = Assistant::HistoryTrimmer.new(messages, max_tokens: 10_000).call

    assert_equal messages, result
  end
end
