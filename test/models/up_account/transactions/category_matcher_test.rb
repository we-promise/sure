require "test_helper"

class UpAccount::Transactions::CategoryMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.categories.bootstrap! # creates Sure's default categories
    @matcher = UpAccount::Transactions::CategoryMatcher.new(@family.categories.to_a)
  end

  test "maps high-confidence Up categories to default Sure categories" do
    expectations = {
      "groceries"                => "Groceries",
      "takeaway"                 => "Food & Drink",
      "restaurants-and-cafes"    => "Food & Drink",
      "tv-and-music"             => "Subscriptions",
      "health-and-medical"       => "Healthcare",
      "fitness-and-wellbeing"    => "Sports & Fitness",
      "hair-and-beauty"          => "Personal Care",
      "clothing-and-accessories" => "Shopping",
      "gifts-and-charity"        => "Gifts & Donations",
      "rent-and-mortgage"        => "Mortgage / Rent",
      "utilities"                => "Utilities",
      "fuel"                     => "Transportation",
      "taxis-and-share-cars"     => "Transportation",
      "home-maintenance-and-improvements" => "Home Improvement"
    }

    expectations.each do |slug, expected_name|
      matched = @matcher.match(slug)
      assert_not_nil matched, "expected '#{slug}' to match a default category"
      assert_equal expected_name, matched.name, "'#{slug}' mapped to the wrong category"
    end
  end

  test "resolves transport children via the parent alias too" do
    assert_equal "Transportation", @matcher.match("parking")&.name
    assert_equal "Transportation", @matcher.match("public-transport")&.name
  end

  test "leaves Up-specific categories with no honest default uncategorised" do
    %w[
      booze adult tobacco-and-vaping lottery-and-gambling pubs-and-bars
      games-and-software technology life-admin pets
    ].each do |slug|
      assert_nil @matcher.match(slug), "expected '#{slug}' to have no confident match"
    end
  end

  test "returns nil for unknown or blank slugs" do
    assert_nil @matcher.match("not-a-real-up-category")
    assert_nil @matcher.match(nil)
    assert_nil @matcher.match("")
  end

  test "does not match when the family has none of the target categories" do
    bare_family = families(:dylan_family)
    bare_family.categories.destroy_all
    matcher = UpAccount::Transactions::CategoryMatcher.new(bare_family.categories.reload.to_a)

    assert_nil matcher.match("groceries"), "no Groceries category exists, so no match"
  end
end
