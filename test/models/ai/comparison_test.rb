require "test_helper"

# Ai::Comparison: what two routes said about the same item, and the readers the shadow
# panel and hostings page use. The migration's rows carry category names in metadata; a row
# built now carries ids.
class Ai::ComparisonTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty) # used to prove tenancy below
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
  end

  test "a garbage value can't match a category, and the query doesn't explode" do
    comparison = comparison(agreed: true, primary_value: "not-a-uuid!!", shadow_value: @coffee.id)

    names = Ai::Comparison.category_names([ comparison ], @family)

    assert_equal @coffee.name, names[@coffee.id.to_s]
    assert_nil names["not-a-uuid!!"]
    assert_nil comparison.category_name(:primary, names)
  end

  test "the agreement rate counts both totals in one query, so a row added meanwhile can't push it past 100%" do
    [ true, true, false ].each { comparison(agreed: _1, primary_value: @coffee.id, shadow_value: @coffee.id) }

    rate = assert_queries_count(1) { @family.ai_comparisons.for_feature(:categorize).agreement_rate }

    assert_in_delta 66.67, rate, 0.01
  end

  test "each side is labelled with its endpoint and model, so two models on one endpoint stay apart" do
    comparison = Ai::Comparison.new(primary_route: { endpoint: "openrouter", model: "qwen3-8b" },
                                    shadow_route: { endpoint: "openrouter", model: "gpt-4.1-mini" })

    assert_equal [ "openrouter/qwen3-8b", "openrouter/gpt-4.1-mini" ], [ comparison.primary_label, comparison.shadow_label ]
  end

  private
    def comparison(agreed:, primary_value:, shadow_value:, metadata: {})
      @family.ai_comparisons.create!(
        feature: "categorize", agreed:, subject_type: "Transaction", subject_id: nil,
        primary_route: { endpoint: "openai", model: "gpt-4.1-mini" },
        shadow_route: { endpoint: "jev", model: "jev-latest" },
        primary_value:, shadow_value:, metadata:
      )
    end
end
