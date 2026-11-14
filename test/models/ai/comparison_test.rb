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
end
