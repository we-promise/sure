require "test_helper"

class Provider::CategoryMatcherTest < ActiveSupport::TestCase
  # Synthetic taxonomy — keeps this test independent of any real provider.
  module FakeTaxonomy
    DATA = {
      "food.restaurants" => { aliases: [ "restaurant", "dining" ],
                              parent_aliases: [ "food", "food and drink" ] },
      "shopping.books"   => { aliases: [ "book", "newsstand" ],
                              parent_aliases: [ "shopping", "retail" ] }
    }.freeze

    def self.resolve(input)
      DATA[input.to_s]
    end
  end

  def setup
    @family = families(:dylan_family)
    # Two real Category rows — by name, so the matcher's normalize/fuzzy
    # logic is exercised against realistic strings. "Food & Drink" already
    # exists for this family via fixture, so reuse it; create "Shopping".
    @food = categories(:food_and_drink)
    @shop = @family.categories.create!(name: "Shopping", color: "#000000", lucide_icon: "shopping-cart")
    # Pass an explicit list rather than the family relation so the test is
    # isolated from other fixture categories (Test, Income, Restaurants).
    @matcher = Provider::CategoryMatcher.new([ @food, @shop ], taxonomy: FakeTaxonomy)
  end

  test "returns nil when taxonomy cannot resolve input" do
    assert_nil @matcher.match("unknown.key")
  end

  test "matches via direct alias" do
    assert_equal @shop, @matcher.match("shopping.books")
  end

  test "matches via parent alias when no direct alias hits" do
    # 'food' / 'food and drink' as parent — direct aliases ('restaurant',
    # 'dining') don't match 'Food & Drink' fuzzily; parent 'food and drink' does.
    assert_equal @food, @matcher.match("food.restaurants")
  end

  test "returns nil when nothing matches" do
    matcher = Provider::CategoryMatcher.new([], taxonomy: FakeTaxonomy)
    assert_nil matcher.match("food.restaurants")
  end

  test "returns nil when no category matches any alias" do
    groceries = @family.categories.create!(name: "Groceries", color: "#000000", lucide_icon: "tag")
    matcher = Provider::CategoryMatcher.new([ groceries ], taxonomy: FakeTaxonomy)
    # 'food.restaurants' aliases: restaurant/dining; parent: food/food and drink. None match 'Groceries'.
    assert_nil matcher.match("food.restaurants")
  end

  test "matches across plural / singular forms" do
    other = @family.categories.create!(name: "Books", color: "#000000", lucide_icon: "tag")
    matcher = Provider::CategoryMatcher.new([ other ], taxonomy: FakeTaxonomy)
    # alias 'book' (singular) should match 'Books' (plural)
    assert_equal other, matcher.match("shopping.books")
  end
end
