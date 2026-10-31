require "test_helper"

class Provider::Openai::UsageCostTest < ActiveSupport::TestCase
  setup do
    @usage = { "prompt_tokens" => 1000, "completion_tokens" => 100, "total_tokens" => 1100 }
    @endpoint = "https://openrouter.ai/api/v1"
  end

  test "uses reported cost for an unknown model without looking up token prices" do
    LlmUsage.expects(:calculate_cost).never

    assert_equal BigDecimal("0.012345"), calculate({ "cost" => 0.012345 })
  end

  test "reported cost overrides a known model's token estimate" do
    assert_equal BigDecimal("0.012345"), calculate({ "cost" => 0.012345 }, model: "gpt-4.1")
  end

  test "preserves zero" do
    [ 0, 0.0 ].each do |cost|
      assert_equal BigDecimal("0"), calculate({ "cost" => cost })
    end
  end

  test "absent and invalid costs fall back to token estimates" do
    invalid_costs = [ nil, -0.1, "-0.1", Float::NAN, Float::INFINITY, -Float::INFINITY,
      "NaN", "Infinity", "", "0.01", "not a cost", "0.01 USD", true, false, [], {} ]
    expected = LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1000, completion_tokens: 100)

    assert_equal expected, calculate({}, model: "gpt-4.1")
    invalid_costs.each do |cost|
      assert_equal expected, calculate({ "cost" => cost }, model: "gpt-4.1"), cost.inspect
      assert_nil calculate({ "cost" => cost }), cost.inspect
    end
  end

  test "fallback accepts Responses API token names" do
    usage = { "input_tokens" => 1000, "output_tokens" => 100, "cost" => nil }

    assert_equal LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1000, completion_tokens: 100),
      Provider::Openai::UsageCost.calculate(model: "gpt-4.1", usage: usage, uri_base: @endpoint)
  end

  test "only official OpenRouter API endpoints supply USD costs" do
    %w[https://openrouter.ai/api/v1/ https://OPENROUTER.AI/api/v1 https://eu.openrouter.ai/api/v1 https://us.openrouter.ai/api/v1].each do |endpoint|
      assert_equal BigDecimal("0.01"), calculate({ "cost" => 0.01 }, uri_base: endpoint)
    end

    [ nil, "https://api.openai.com/v1", "https://custom.example/v1", "http://openrouter.ai/api/v1",
      "https://openrouter.ai.example/api/v1", "https://openrouter.ai:8443/api/v1",
      "https://openrouter.ai/api/other", "not a URL" ].each do |endpoint|
      assert_nil calculate({ "cost" => 0.01 }, uri_base: endpoint), endpoint.inspect
      assert_equal LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1000, completion_tokens: 100),
        calculate({ "cost" => 0.01 }, model: "gpt-4.1", uri_base: endpoint)
    end
  end

  private
    def calculate(extra_usage, model: "deepseek/example-model", uri_base: @endpoint)
      Provider::Openai::UsageCost.calculate(model: model, usage: @usage.merge(extra_usage), uri_base: uri_base)
    end
end
