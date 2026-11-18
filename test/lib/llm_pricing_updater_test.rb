require "test_helper"

class LlmPricingUpdaterTest < ActiveSupport::TestCase
  CONFIG = <<~YAML
    verified_on: 2026-10-17

    providers:
      openai:
        # GPT-6
        gpt-6.1-sol: &gpt-6-1-sol { prompt: 2.0, completion: 10.0 } # promotion {ends Q4}
        gpt-4.1: { prompt: 2.0, completion: 8.0 }
        gpt-sol: *gpt-6-1-sol
      anthropic:
        claude-opus-5-5: &claude-opus-5-5 { prompt: 4.0, completion: 20.0, cache_read: 0.2 }
        claude-opus: *claude-opus-5-5
  YAML

  test "rewrites changed rows in place, keeping comments, anchors and aliases" do
    result = update(
      "gpt-6.1-sol" => litellm(3, 12, "input_cost_per_token_above_272k_tokens" => 6e-6, "output_cost_per_token_above_272k_tokens" => 18e-6),
      "gpt-4.1" => litellm(2, 8),
      "claude-opus-5-5" => litellm(4, 20, provider: "anthropic", "cache_read_input_token_cost" => 0.2e-6)
    )

    assert_includes result.yaml, "    gpt-6.1-sol: &gpt-6-1-sol { prompt: 3.0, completion: 12.0, " \
      "long_context: { threshold: 272000, prompt: 6.0, completion: 18.0 } } # promotion {ends Q4}\n"
    assert_includes result.yaml, "    # GPT-6\n"
    assert_includes result.yaml, "    gpt-4.1: { prompt: 2.0, completion: 8.0 }\n"
    assert_equal 1, result.changed.size
    assert_empty result.added
    assert_empty result.missing

    loaded = YAML.safe_load(result.yaml, permitted_classes: [ Date ], aliases: true)
    assert_equal 3.0, loaded.dig("providers", "openai", "gpt-sol", "prompt")
  end

  test "adds new Claude and GPT tier releases only" do
    result = update(
      "claude-opus-6" => litellm(4, 20, provider: "anthropic", "cache_read_input_token_cost" => 0.4e-6),
      "claude-sonnet-6" => litellm(2, 10, provider: "anthropic", "cache_read_input_token_cost" => 0.1e-6),
      "claude-opus-4-20250514" => litellm(15, 75, provider: "anthropic"),
      "claude-opus-4-0" => litellm(15, 75, provider: "anthropic"),
      "claude-haiku-6" => litellm(0.1, 0.5, provider: "bedrock"),
      "gpt-6.2-sol" => litellm(2, 10),
      "gpt-5.9" => litellm(1, 8)
    )

    lines = result.yaml.lines(chomp: true)
    assert_equal "    claude-opus-6: { prompt: 4.0, completion: 20.0 }", lines[lines.index("  anthropic:") + 3]
    assert_equal "    claude-sonnet-6: { prompt: 2.0, completion: 10.0, cache_read: 0.1 }", lines[lines.index("  anthropic:") + 2]
    assert_equal "    gpt-6.2-sol: { prompt: 2.0, completion: 10.0 }", lines[lines.index("  openai:") + 2]
    assert_equal 3, result.added.size
  end

  test "skips source data it cannot trust and reports those rows as missing" do
    result = update(
      "gpt-6.1-sol" => litellm(-1, 10),
      "gpt-4.1" => litellm(2, 8, provider: "azure"),
      "claude-opus-5-5" => litellm(4, "20", provider: "anthropic")
    )

    assert_equal CONFIG, result.yaml
    assert_equal 3, result.missing.size
  end

  test "keeps reviewed long-context tiers and cache rates that LiteLLM cannot confirm" do
    config = <<~YAML
      providers:
        openai:
          gpt-5.4: { prompt: 2.5, completion: 15.0, long_context: { threshold: 272000, prompt: 5.0, completion: 22.5 } }
          gpt-5.5: { prompt: 5.0, completion: 30.0, long_context: { threshold: 272000, prompt: 10.0, completion: 45.0 } }
        anthropic:
          claude-opus-5-5: { prompt: 4.0, completion: 20.0, cache_read: 0.2 }
    YAML

    result = LlmPricingUpdater.new(config,
      "gpt-5.4" => litellm(3, 15),
      "gpt-5.5" => litellm(6, 30, "input_cost_per_token_above_272k_tokens" => 12e-6, "output_cost_per_token_above_272k_tokens" => "45"),
      "claude-opus-5-5" => litellm(4, 20, provider: "anthropic")
    ).call

    assert_equal config, result.yaml
    assert_empty result.changed
    assert_equal 3, result.missing.size
  end

  test "the bundled config is unchanged when LiteLLM matches it" do
    prices = LlmUsage::PRICING.flat_map do |provider, models|
      prefix, litellm_provider = LlmPricingUpdater::LITELLM.fetch(provider)
      models.map do |model, pricing|
        long_context = pricing[:long_context]
        extra = { "cache_read_input_token_cost" => (pricing[:cache_read] || pricing[:prompt] * 0.1) / 1e6 }
        if long_context
          tokens = "above_#{long_context[:threshold] / 1000}k_tokens"
          extra["input_cost_per_token_#{tokens}"] = long_context[:prompt] / 1e6
          extra["output_cost_per_token_#{tokens}"] = long_context[:completion] / 1e6
        end
        [ "#{prefix}#{model}", litellm(pricing[:prompt], pricing[:completion], provider: litellm_provider, **extra) ]
      end
    end.to_h
    config = Rails.root.join("config/llm_pricing.yml").read

    result = LlmPricingUpdater.new(config, prices).call

    assert_empty result.changed
    assert_empty result.added
    assert_empty result.missing
    assert_equal config, result.yaml
  end

  private
    def update(prices)
      LlmPricingUpdater.new(CONFIG, prices).call
    end

    def litellm(input, output, provider: "openai", **extra)
      input = input / 1e6 if input.is_a?(Numeric)
      output = output / 1e6 if output.is_a?(Numeric)
      { "litellm_provider" => provider, "input_cost_per_token" => input, "output_cost_per_token" => output }.merge(extra.transform_keys(&:to_s))
    end
end
