require "test_helper"

class LlmUsageTest < ActiveSupport::TestCase
  test "infer_provider returns anthropic for claude models" do
    assert_equal "anthropic", LlmUsage.infer_provider("claude-sonnet-4-6")
    assert_equal "anthropic", LlmUsage.infer_provider("claude-opus-4-7")
    assert_equal "anthropic", LlmUsage.infer_provider("claude-haiku-4-5")
  end

  test "infer_provider still returns openai for gpt models" do
    assert_equal "openai", LlmUsage.infer_provider("gpt-4.1")
    assert_equal "openai", LlmUsage.infer_provider("gpt-5")
  end

  test "calculate_cost returns Anthropic pricing for Claude models" do
    cost = LlmUsage.calculate_cost(model: "claude-sonnet-4-6", prompt_tokens: 1_000_000, completion_tokens: 100_000)

    # 1M input * $3/MTok + 100K output * $15/MTok = $3.00 + $1.50 = $4.50
    assert_in_delta 4.5, cost, 0.0001
  end

  test "calculate_cost uses higher pricing for Opus" do
    cost = LlmUsage.calculate_cost(model: "claude-opus-4-7", prompt_tokens: 1_000_000, completion_tokens: 0)

    # 1M input * $15/MTok = $15.00
    assert_in_delta 15.0, cost, 0.0001
  end

  test "calculate_cost uses lower pricing for Haiku" do
    cost = LlmUsage.calculate_cost(model: "claude-haiku-4-5", prompt_tokens: 1_000_000, completion_tokens: 1_000_000)

    # $1 in + $5 out = $6.00
    assert_in_delta 6.0, cost, 0.0001
  end
end
