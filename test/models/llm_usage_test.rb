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

  test "infer_provider attributes Bedrock and Vertex prefixed IDs to anthropic" do
    assert_equal "anthropic", LlmUsage.infer_provider("anthropic.claude-sonnet-4-5-20250929-v1:0")
    assert_equal "anthropic", LlmUsage.infer_provider("anthropic.claude-opus-4-20250514-v1:0")
    assert_equal "anthropic", LlmUsage.infer_provider("anthropic/claude-3-5-sonnet@20240620")
  end

  test "calculate_cost returns nil for Bedrock IDs (no per-token rate stored)" do
    # Bedrock bills through AWS not Anthropic — we don't store a per-MTok rate,
    # but the row must still attribute to anthropic for provider filtering.
    assert_nil LlmUsage.calculate_cost(
      model: "anthropic.claude-sonnet-4-5-20250929-v1:0",
      prompt_tokens: 1000,
      completion_tokens: 500
    )
  end


  test "calculate_cost uses current OpenAI pricing" do
    gpt_54 = LlmUsage.calculate_cost(model: "gpt-5.4", prompt_tokens: 1_000_000, completion_tokens: 100_000)
    assert_in_delta 4.0, gpt_54, 0.0001

    nano = LlmUsage.calculate_cost(model: "gpt-4.1-nano", prompt_tokens: 1_000_000, completion_tokens: 1_000_000)
    assert_in_delta 0.5, nano, 0.0001
  end

  test "calculate_cost prices snapshot model IDs with the most specific OpenAI prefix" do
    mini = LlmUsage.calculate_cost(
      model: "gpt-5.4-mini-2026-03-17",
      prompt_tokens: 1_000_000,
      completion_tokens: 100_000
    )
    assert_in_delta 1.2, mini, 0.0001

    pro = LlmUsage.calculate_cost(
      model: "gpt-5.4-pro-2026-03-17",
      prompt_tokens: 100_000,
      completion_tokens: 10_000
    )
    assert_in_delta 4.8, pro, 0.0001
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

  test "calculate_cost prices Anthropic cache tokens relative to the input rate" do
    # Sonnet input is $3/MTok → cache write 1.25x = $3.75/MTok, read 0.1x = $0.30/MTok.
    write = LlmUsage.calculate_cost(model: "claude-sonnet-4-6", prompt_tokens: 0, completion_tokens: 0, cache_creation_tokens: 1_000_000)
    assert_in_delta 3.75, write, 0.0001

    read = LlmUsage.calculate_cost(model: "claude-sonnet-4-6", prompt_tokens: 0, completion_tokens: 0, cache_read_tokens: 1_000_000)
    assert_in_delta 0.30, read, 0.0001
  end

  test "calculate_cost matches Anthropic's bill for a cached chat turn (issue #1984)" do
    # Real tokens from the review: ignoring cache tokens under-reports ($0.0328 vs $0.0355).
    cost = LlmUsage.calculate_cost(
      model: "claude-sonnet-4-6",
      prompt_tokens: 8082, completion_tokens: 572,
      cache_creation_tokens: 435, cache_read_tokens: 3502
    )
    assert_in_delta 0.035508, cost, 0.0001

    without_cache = LlmUsage.calculate_cost(model: "claude-sonnet-4-6", prompt_tokens: 8082, completion_tokens: 572)
    assert cost > without_cache, "cache tokens must add cost"
  end

  test "calculate_cost treats nil cache tokens as zero (OpenAI rows)" do
    # gpt-4.1 input is $2/MTok; nil cache columns must not blow up or add cost.
    cost = LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1_000_000, completion_tokens: 0, cache_creation_tokens: nil, cache_read_tokens: nil)
    assert_in_delta 2.0, cost, 0.0001
  end

  test "calculate_cost does not apply Anthropic cache pricing to non-Anthropic models" do
    # The 1.25x/0.1x cache multipliers are Anthropic's. If a non-Anthropic caller
    # ever passes cache counts, they must not be billed with the wrong rates.
    cost = LlmUsage.calculate_cost(
      model: "gpt-4.1", prompt_tokens: 0, completion_tokens: 0,
      cache_creation_tokens: 1_000_000, cache_read_tokens: 1_000_000
    )
    assert_in_delta 0.0, cost, 0.0001
  end
end
