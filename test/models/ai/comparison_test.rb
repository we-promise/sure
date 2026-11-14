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

  test "agreement_rate is nil with no comparisons, and counts agreed rows otherwise" do
    assert_nil @family.categorization_comparisons.agreement_rate

    comparison(agreed: true, primary_value: @coffee.id, shadow_value: @coffee.id)
    comparison(agreed: false, primary_value: @coffee.id, shadow_value: @groceries.id)
    comparison(agreed: true, primary_value: nil, shadow_value: nil)

    assert_in_delta 66.67, @family.categorization_comparisons.agreement_rate, 0.01
  end

  test "disagreements scope keeps only rejected rows, and scopes to the family" do
    comparison(agreed: true, primary_value: @coffee.id, shadow_value: @coffee.id)
    disagreement = comparison(agreed: false, primary_value: @coffee.id, shadow_value: @groceries.id)

    assert_equal [ disagreement ], @family.categorization_comparisons.disagreements.to_a
    assert_empty @other_family.ai_comparisons.where(feature: "categorize")
  end

  test "a garbage value can't match a category, and the query doesn't explode" do
    comparison = comparison(agreed: true, primary_value: "not-a-uuid!!", shadow_value: @coffee.id)

    names = Ai::Comparison.category_names([ comparison ], @family)

    assert_equal @coffee.name, names[@coffee.id.to_s]
    assert_nil names["not-a-uuid!!"]
    assert_nil comparison.category_name(:primary, names)
  end

  test "category_names resolves the family's ids, skipping blanks and rows that can't match" do
    comparison = comparison(agreed: true, primary_value: @coffee.id, shadow_value: @groceries.id)

    names = Ai::Comparison.category_names([ comparison ], @family)

    assert_equal @coffee.name, names[@coffee.id.to_s]
    assert_equal @groceries.name, names[@groceries.id.to_s]
  end

  test "a migrated row resolves its category name from metadata, and stays nil when the id is unknown" do
    legacy = comparison(agreed: false, primary_value: nil, shadow_value: nil, metadata: {
      "primary_category_name" => "Deleted Coffee", "shadow_category_name" => "Deleted Groceries"
    })
    current = comparison(agreed: true, primary_value: SecureRandom.uuid, shadow_value: nil)

    names = Ai::Comparison.category_names([ legacy, current ], @family)

    assert_equal "Deleted Coffee", legacy.category_name(:primary, names)
    assert_equal "Deleted Groceries", legacy.category_name(:shadow, names)
    assert_nil current.category_name(:primary, names)
    assert_nil current.category_name(:shadow, names)
  end

  test "with_display_names resolves both sides in one pass, for rendering without re-querying" do
    comparison = comparison(agreed: false, primary_value: @coffee.id, shadow_value: SecureRandom.uuid)

    resolved = Ai::Comparison.with_display_names([ comparison ], @family).sole

    assert_equal "Coffee", resolved.primary_name
    assert_nil resolved.shadow_name, "an unknown id renders as nil, not the id"
  end

  test "with_display_names falls back to the metadata name for migrated rows" do
    comparison = comparison(agreed: false, primary_value: nil, shadow_value: nil, metadata: {
      "primary_category_name" => "Deleted Coffee", "shadow_category_name" => "Deleted Groceries"
    })

    resolved = Ai::Comparison.with_display_names([ comparison ], @family).sole

    assert_equal "Deleted Coffee", resolved.primary_name
    assert_equal "Deleted Groceries", resolved.shadow_name
  end

  test "endpoints read their side of the stored route" do
    comparison = comparison(agreed: true, primary_value: nil, shadow_value: nil)

    assert_equal "openai", comparison.primary_endpoint
    assert_equal "jev", comparison.shadow_endpoint
  end

  test "family.categorization_comparisons selects only categorize comparisons" do
    categorize = comparison(agreed: true, primary_value: nil, shadow_value: nil)
    other = @family.ai_comparisons.create!(feature: "detect_merchants", agreed: true,
                                          subject_type: "Transaction",
                                          primary_route: { endpoint: "openai" }, shadow_route: { endpoint: "jev" })

    assert_equal [ categorize ], @family.categorization_comparisons.to_a
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
