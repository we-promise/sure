require "test_helper"

class BudgetCategory::SearchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @food = categories(:food_and_drink)
    @other_category = @family.categories.create!(name: "Search test category", color: "#123456")

    march = @family.budgets.create!(start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31), currency: "USD")
    april = @family.budgets.create!(start_date: Date.new(2024, 4, 1), end_date: Date.new(2024, 4, 30), currency: "USD")
    @march_food = march.budget_categories.create!(category: @food, budgeted_spending: 100, currency: "USD")
    @march_other = march.budget_categories.create!(category: @other_category, budgeted_spending: 100, currency: "USD")
    @april_food = april.budget_categories.create!(category: @food, budgeted_spending: 100, currency: "USD")

    @scope = BudgetCategory.where(id: [ @march_food, @march_other, @april_food ].map(&:id))
  end

  test "with no filters returns the scope it is given" do
    assert_equal ids(@march_food, @march_other, @april_food), ids(*BudgetCategory::Search.new(@scope).budget_categories_scope)
  end

  test "budget_id keeps the categories of that budget" do
    assert_equal ids(@march_food, @march_other), ids(*search(budget_id: @march_food.budget_id))
  end

  test "category_id keeps the rows for that category" do
    assert_equal ids(@march_food, @april_food), ids(*search(category_id: @food.id))
  end

  test "start_date and end_date filter on the budget's dates" do
    assert_equal ids(@april_food), ids(*search(start_date: Date.new(2024, 4, 1)))
    assert_equal ids(@march_food, @march_other), ids(*search(end_date: Date.new(2024, 3, 31)))
    assert_equal ids(@march_food), ids(*search(category_id: @food.id, start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 4, 29)))
  end

  test "date filters work on a scope that already joins budgets" do
    joined = @scope.joins(:budget, :category)

    assert_equal ids(@april_food), ids(*BudgetCategory::Search.new(joined, filters: { start_date: Date.new(2024, 4, 1) }).budget_categories_scope)
  end

  test "never widens the scope it is given" do
    assert_empty search_on(@scope.where(id: @march_other.id), category_id: @food.id)
  end

  private
    def search(**filters)
      search_on(@scope, **filters)
    end

    def search_on(scope, **filters)
      BudgetCategory::Search.new(scope, filters:).budget_categories_scope
    end

    def ids(*records)
      records.map(&:id).sort
    end
end
