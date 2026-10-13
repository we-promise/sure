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

  test "infer_provider returns google for gemini and google/ models" do
    assert_equal "google", LlmUsage.infer_provider("gemini-3.8-flash")
    assert_equal "google", LlmUsage.infer_provider("gemini-3.1-pro")
    assert_equal "google", LlmUsage.infer_provider("gemini-2.5-flash")
    assert_equal "google", LlmUsage.infer_provider("gemini-unknown-model")
    assert_equal "google", LlmUsage.infer_provider("google/gemini-2.5-flash")
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
    assert_in_delta 7.25, gpt_54, 0.0001

    nano = LlmUsage.calculate_cost(model: "gpt-4.1-nano", prompt_tokens: 1_000_000, completion_tokens: 1_000_000)
    assert_in_delta 0.5, nano, 0.0001
  end

  %w[gpt-6-sol gpt-6.1-sol].each do |model|
    test "calculate_cost estimates #{model} usage at Standard pricing" do
      cost = LlmUsage.calculate_cost(
        model: model,
        prompt_tokens: 100_000,
        completion_tokens: 10_000
      )

      assert_in_delta 0.3, cost, 0.0001
    end

    test "calculate_cost applies #{model} long-context rates to the full request" do
      cost = LlmUsage.calculate_cost(
        model: model, prompt_tokens: 1_000_000, completion_tokens: 100_000
      )

      assert_in_delta 5.5, cost, 0.0001
    end

    test "#{model} long-context pricing starts strictly above 272000 input tokens" do
      at_threshold = LlmUsage.calculate_cost(
        model: model, prompt_tokens: 272_000, completion_tokens: 100_000
      )
      above_threshold = LlmUsage.calculate_cost(
        model: model, prompt_tokens: 272_001, completion_tokens: 100_000
      )

      assert_in_delta 1.544, at_threshold, 0.000001
      assert_in_delta 2.588004, above_threshold, 0.000001
    end

    test "#{model} bulk categorization estimates do not treat aggregate tokens as one long-context request" do
      cost = LlmUsage.estimate_auto_categorize_cost(
        model: model, transaction_count: 10_000, category_count: 20
      )

      assert_in_delta 7.0023, cost, 0.0001
    end
  end

  test "large requests for legacy models retain their existing pricing" do
    cost = LlmUsage.calculate_cost(
      model: "gpt-4.1", prompt_tokens: 1_000_000, completion_tokens: 100_000
    )

    assert_in_delta 2.8, cost, 0.0001
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

  test "calculate_cost uses reviewed OpenAI pricing for GPT-5.2 aliases and pro" do
    chat_latest = LlmUsage.calculate_cost(
      model: "gpt-5.2-chat-latest",
      prompt_tokens: 1_000_000,
      completion_tokens: 100_000
    )
    assert_in_delta 3.15, chat_latest, 0.0001

    pro = LlmUsage.calculate_cost(
      model: "gpt-5.2-pro",
      prompt_tokens: 1_000_000,
      completion_tokens: 100_000
    )
    assert_in_delta 37.8, pro, 0.0001
  end

  test "calculate_cost returns Anthropic pricing for Claude models" do
    cost = LlmUsage.calculate_cost(model: "claude-sonnet-4-6", prompt_tokens: 1_000_000, completion_tokens: 100_000)

    # 1M input * $3/MTok + 100K output * $15/MTok = $3.00 + $1.50 = $4.50
    assert_in_delta 4.5, cost, 0.0001
  end

  %w[claude-opus-4-6 claude-opus-4-7].each do |model|
    test "calculate_cost uses corrected input output and cache rates for #{model}" do
      cost = LlmUsage.calculate_cost(
        model: model, prompt_tokens: 100_000, completion_tokens: 10_000,
        cache_creation_tokens: 20_000, cache_read_tokens: 50_000
      )

      # $0.50 input + $0.25 output + $0.125 cache write + $0.025 cache read.
      assert_in_delta 0.9, cost, 0.000001
    end
  end

  {
    "gpt-5.6-sol" => [ 6.0, 11.0 ],
    "gpt-5.6-terra" => [ 3.2, 5.8 ],
    "gpt-5.6-luna" => [ 0.32, 0.58 ],
    "gpt-5.5" => [ 8.0, 14.5 ],
    "gpt-5.5-pro" => [ 48.0, 87.0 ],
    "gpt-5.4" => [ 4.0, 7.25 ],
    "gpt-5.4-pro" => [ 48.0, 87.0 ],
    "gemini-2.5-pro" => [ 2.25, 4.0 ],
    "gemini-3.1-pro" => [ 3.2, 5.8 ]
  }.each do |model, (short_cost, long_cost)|
    test "calculate_cost uses reviewed short and long context rates for #{model}" do
      assert_in_delta short_cost / 10, LlmUsage.calculate_cost(
        model: model, prompt_tokens: 100_000, completion_tokens: 10_000
      ), 0.000001
      assert_in_delta long_cost, LlmUsage.calculate_cost(
        model: model, prompt_tokens: 1_000_000, completion_tokens: 100_000
      ), 0.000001
    end
  end

  test "Gemini 2.5 Pro long-context pricing starts strictly above 200000 input tokens" do
    assert_in_delta 1.25, LlmUsage.calculate_cost(
      model: "gemini-2.5-pro", prompt_tokens: 200_000, completion_tokens: 100_000
    ), 0.000001
    assert_in_delta 2.000003, LlmUsage.calculate_cost(
      model: "gemini-2.5-pro", prompt_tokens: 200_001, completion_tokens: 100_000
    ), 0.000001
  end

  test "Gemini 3.1 Pro long-context pricing starts strictly above 200000 input tokens" do
    assert_in_delta 1.60, LlmUsage.calculate_cost(
      model: "gemini-3.1-pro", prompt_tokens: 200_000, completion_tokens: 100_000
    ), 0.000001
    assert_in_delta 2.600004, LlmUsage.calculate_cost(
      model: "gemini-3.1-pro", prompt_tokens: 200_001, completion_tokens: 100_000
    ), 0.000001
  end

  test "GPT-5.6 long-context pricing starts strictly above 272000 input tokens" do
    assert_in_delta 3.088, LlmUsage.calculate_cost(
      model: "gpt-5.6-sol", prompt_tokens: 272_000, completion_tokens: 100_000
    ), 0.000001
    assert_in_delta 5.176008, LlmUsage.calculate_cost(
      model: "gpt-5.6-sol", prompt_tokens: 272_001, completion_tokens: 100_000
    ), 0.000001
  end

  test "Gemini bulk categorization estimates retain short-context rates" do
    assert_in_delta 6.251438, LlmUsage.estimate_auto_categorize_cost(
      model: "gemini-2.5-pro", transaction_count: 10_000, category_count: 20
    ), 0.000001
  end

  test "calculate_cost returns Google pricing for Gemini 3 models" do
    # gemini-3.8-flash, 3.7-flash, 3.6-flash: $0.75 prompt / $3.75 completion per 1M tokens
    %w[gemini-3.8-flash gemini-3.7-flash gemini-3.6-flash].each do |model|
      cost = LlmUsage.calculate_cost(model: model, prompt_tokens: 1_000_000, completion_tokens: 100_000)
      assert_in_delta 1.125, cost, 0.0001
    end

    # gemini-3.5-flash: $1.50 prompt / $9.00 completion per 1M tokens
    cost_35_flash = LlmUsage.calculate_cost(model: "gemini-3.5-flash", prompt_tokens: 1_000_000, completion_tokens: 100_000)
    assert_in_delta 2.40, cost_35_flash, 0.0001

    # gemini-3.5-flash-lite: $0.30 prompt / $2.50 completion per 1M tokens
    cost_35_lite = LlmUsage.calculate_cost(model: "gemini-3.5-flash-lite", prompt_tokens: 1_000_000, completion_tokens: 100_000)
    assert_in_delta 0.55, cost_35_lite, 0.0001

    # gemini-3.1-flash-lite: $0.25 prompt / $1.50 completion per 1M tokens
    cost_31_lite = LlmUsage.calculate_cost(model: "gemini-3.1-flash-lite", prompt_tokens: 1_000_000, completion_tokens: 100_000)
    assert_in_delta 0.40, cost_31_lite, 0.0001

    # gemini-3-flash: $0.50 prompt / $3.00 completion per 1M tokens
    cost_3_flash = LlmUsage.calculate_cost(model: "gemini-3-flash", prompt_tokens: 1_000_000, completion_tokens: 100_000)
    assert_in_delta 0.80, cost_3_flash, 0.0001
  end

  test "find_pricing and calculate_cost normalize provider prefix for OpenRouter models" do
    pricing = LlmUsage.find_pricing("google", "google/gemini-3.8-flash")
    assert_not_nil pricing
    assert_equal 0.75, pricing[:prompt]
    assert_equal 3.75, pricing[:completion]

    assert_equal 2.00, LlmUsage.find_pricing("openai", "openai/gpt-4.1")[:prompt]
    assert_equal 3.00, LlmUsage.find_pricing("anthropic", "anthropic/claude-sonnet-4-5")[:prompt]

    cost = LlmUsage.calculate_cost(
      model: "google/gemini-3.8-flash",
      prompt_tokens: 1_000_000,
      completion_tokens: 100_000
    )
    assert_in_delta 1.125, cost, 0.0001
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
