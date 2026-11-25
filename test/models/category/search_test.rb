require "test_helper"

class Category::SearchTest < ActiveSupport::TestCase
  setup do
    @scope = families(:dylan_family).categories
  end

  test "returns the whole scope when no filter is set" do
    assert_equal @scope.ids.sort, Category::Search.new(@scope).categories_scope.ids.sort
  end

  test "roots_only keeps categories without a parent" do
    results = Category::Search.new(@scope, filters: { roots_only: true }).categories_scope

    assert_includes results, categories(:food_and_drink)
    assert_not_includes results, categories(:subcategory)
  end

  test "roots_only false is the same as no filter" do
    assert_equal @scope.ids.sort, Category::Search.new(@scope, filters: { roots_only: false }).categories_scope.ids.sort
  end

  test "parent_id keeps the subcategories of that parent" do
    results = Category::Search.new(@scope, filters: { parent_id: categories(:food_and_drink).id }).categories_scope

    assert_equal [ categories(:subcategory) ], results.to_a
  end

  test "never widens the scope it is given" do
    narrowed = @scope.where.not(id: categories(:subcategory).id)

    assert_empty Category::Search.new(narrowed, filters: { parent_id: categories(:food_and_drink).id }).categories_scope
  end
end
