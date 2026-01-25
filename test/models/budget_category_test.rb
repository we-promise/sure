require "test_helper"

class BudgetCategoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)

    # Create parent category with unique name
    @parent_category = Category.create!(
      name: "Test Food & Groceries #{Time.now.to_f}",
      family: @family,
      color: "#4da568",
      lucide_icon: "utensils",
      classification: "expense"
    )

    # Create subcategories with unique names
    @subcategory_with_limit = Category.create!(
      name: "Test Restaurants #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    @subcategory_inheriting = Category.create!(
      name: "Test Groceries #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    # Create budget categories
    @parent_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @parent_category,
      budgeted_spending: 1000,
      currency: "USD"
    )

    @subcategory_with_limit_bc = BudgetCategory.create!(
      budget: @budget,
      category: @subcategory_with_limit,
      budgeted_spending: 300,
      currency: "USD"
    )

    @subcategory_inheriting_bc = BudgetCategory.create!(
      budget: @budget,
      category: @subcategory_inheriting,
      budgeted_spending: 0,  # Inherits from parent
      currency: "USD"
    )
  end

  test "subcategory with zero budget inherits from parent" do
    assert @subcategory_inheriting_bc.inherits_parent_budget?
    refute @subcategory_with_limit_bc.inherits_parent_budget?
    refute @parent_budget_category.inherits_parent_budget?
  end

  test "parent_budget_category returns parent for subcategories" do
    assert_equal @parent_budget_category, @subcategory_inheriting_bc.parent_budget_category
    assert_equal @parent_budget_category, @subcategory_with_limit_bc.parent_budget_category
    assert_nil @parent_budget_category.parent_budget_category
  end

  test "display_budgeted_spending shows parent budget for inheriting subcategories" do
    assert_equal 1000, @subcategory_inheriting_bc.display_budgeted_spending
    assert_equal 300, @subcategory_with_limit_bc.display_budgeted_spending
    assert_equal 1000, @parent_budget_category.display_budgeted_spending
  end

  test "inheriting subcategory shares parent available_to_spend" do
    # Mock the actual spending values
    # Parent's actual_spending from income_statement includes all children
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(150)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(50)

    # Parent available calculation:
    # shared_pool = 1000 (parent budget) - 300 (subcategory with limit budget) = 700
    # shared_pool_spending = 150 (total) - 100 (subcategory with limit spending) = 50
    # available = 700 - 50 = 650
    assert_equal 650, @parent_budget_category.available_to_spend

    # Inheriting subcategory shares parent's available (650)
    assert_equal 650, @subcategory_inheriting_bc.available_to_spend

    # Subcategory with limit: 300 (its budget) - 100 (its spending) = 200
    assert_equal 200, @subcategory_with_limit_bc.available_to_spend
  end

  test "max_allocation excludes budgets of inheriting siblings" do
    # Create another inheriting subcategory
    another_inheriting = Category.create!(
      name: "Test Coffee #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    another_inheriting_bc = BudgetCategory.create!(
      budget: @budget,
      category: another_inheriting,
      budgeted_spending: 0,  # Inherits
      currency: "USD"
    )

    # Max allocation for new subcategory should only account for the one with explicit limit (300)
    # 1000 (parent) - 300 (subcategory_with_limit) = 700
    assert_equal 700, another_inheriting_bc.max_allocation

    # If we add a new subcategory with a limit
    new_subcategory_cat = Category.create!(
      name: "Test Fast Food #{Time.now.to_f}",
      parent: @parent_category,
      family: @family,
      classification: "expense"
    )

    new_subcategory_bc = BudgetCategory.create!(
      budget: @budget,
      category: new_subcategory_cat,
      budgeted_spending: 0,
      currency: "USD"
    )

    # Max should still be 700 because both inheriting subcategories don't count
    assert_equal 700, new_subcategory_bc.max_allocation
  end

  test "percent_of_budget_spent for inheriting subcategory uses parent budget" do
    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(100)

    # 100 / 1000 (parent budget) = 10%
    assert_equal 10.0, @subcategory_inheriting_bc.percent_of_budget_spent
  end

  test "parent with no subcategories works as before" do
    # Create a standalone parent category without subcategories
    standalone_category = Category.create!(
      name: "Test Entertainment #{Time.now.to_f}",
      family: @family,
      color: "#a855f7",
      lucide_icon: "drama",
      classification: "expense"
    )

    standalone_bc = BudgetCategory.create!(
      budget: @budget,
      category: standalone_category,
      budgeted_spending: 500,
      currency: "USD"
    )

    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(standalone_bc).returns(200)

    # Should work exactly as before: 500 - 200 = 300
    assert_equal 300, standalone_bc.available_to_spend
    assert_equal 40.0, standalone_bc.percent_of_budget_spent
  end

  test "parent with only inheriting subcategories shares entire budget" do
    # Set subcategory_with_limit to also inherit
    @subcategory_with_limit_bc.update!(budgeted_spending: 0)

    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(200)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(100)

    # All should show same available: 1000 - 200 = 800
    assert_equal 800, @parent_budget_category.available_to_spend
    assert_equal 800, @subcategory_with_limit_bc.available_to_spend
    assert_equal 800, @subcategory_inheriting_bc.available_to_spend
  end
end
