require "test_helper"

class Ai::ComparisonTest < ActiveSupport::TestCase
  test "the agreement rate counts both totals in one query, so a row added meanwhile can't push it past 100%" do
    family = families(:dylan_family)
    [ true, true, false ].each do |agreed|
      Ai::Comparison.create!(family:, feature: "categorize", primary_route: { endpoint: "openai" }, shadow_route: { endpoint: "jev" }, agreed:)
    end
    comparisons = family.ai_comparisons.for_feature(:categorize)

    rate = assert_queries_count(1) { comparisons.agreement_rate }

    assert_in_delta 66.67, rate, 0.01
    assert_nil family.ai_comparisons.for_feature(:detect_merchants).agreement_rate
  end

  test "each side is labelled with its endpoint and model, so two models on one endpoint stay apart" do
    comparison = Ai::Comparison.new(primary_route: { endpoint: "openrouter", model: "qwen3-8b" },
                                    shadow_route: { endpoint: "openrouter", model: "gpt-4.1-mini" })

    assert_equal [ "openrouter/qwen3-8b", "openrouter/gpt-4.1-mini" ], [ comparison.primary_label, comparison.shadow_label ]
  end
end
