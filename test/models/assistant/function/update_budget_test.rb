require "test_helper"

class Assistant::Function::UpdateBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @budget = budgets(:one)
    @function = Assistant::Function::UpdateBudget.new(@user)
  end

  test "has correct name" do
    assert_equal "update_budget", @function.name
  end

  test "has a description" do
    assert_not_empty @function.description
  end

  test "is not in strict mode" do
    refute @function.strict_mode?
  end

  test "params_schema declares month totals and categories as optional" do
    schema = @function.params_schema
    assert schema[:properties].key?(:month)
    assert schema[:properties].key?(:budgeted_spending)
    assert schema[:properties].key?(:expected_income)
    assert schema[:properties].key?(:categories)
    assert_empty schema[:required]
  end

  test "updates totals for the current month by default" do
    result = @function.call(
      "budgeted_spending" => 6500,
      "expected_income" => 9000
    )

    assert_equal true, result[:success]
    assert_equal @budget.to_param, result[:month]

    @budget.reload
    assert_equal 6500, @budget.budgeted_spending
    assert_equal 9000, @budget.expected_income
  end

  test "sets a category allocation by case-insensitive name" do
    @budget.sync_budget_categories

    result = @function.call(
      "categories" => [ { "category" => "food & drink", "amount" => 450 } ]
    )

    assert_equal true, result[:success]
    assert_equal 1, result[:updated_categories].length
    assert_equal "Food & Drink", result[:updated_categories].first[:category]

    budget_category = @budget.budget_categories
      .joins(:category).find_by(categories: { name: "Food & Drink" })
    assert_equal 450, budget_category.reload.budgeted_spending
  end

  test "sets a category allocation by id and keeps a subcategory's parent in sync" do
    @budget.sync_budget_categories
    subcategory = categories(:subcategory)
    parent = subcategory.parent

    result = @function.call(
      "categories" => [ { "category" => subcategory.id, "amount" => 120 } ]
    )

    assert_equal true, result[:success]

    sub_bc = @budget.budget_categories.find_by(category_id: subcategory.id)
    parent_bc = @budget.budget_categories.find_by(category_id: parent.id)
    assert_equal 120, sub_bc.reload.budgeted_spending
    assert_operator parent_bc.reload.budgeted_spending, :>=, 120
  end

  test "bootstraps a budget when targeting a valid month with no budget row" do
    target = Date.current.beginning_of_month << 1
    assert_nil @family.budgets.find_by(start_date: target)

    result = @function.call(
      "month" => target.strftime("%Y-%m"),
      "budgeted_spending" => 1000
    )

    assert_equal true, result[:success]
    created = @family.budgets.find_by(start_date: target)
    assert_equal 1000, created.budgeted_spending
  end

  test "rejects a category outside the family and rolls back totals from the same call" do
    other_family_category = Category.create!(
      family: families(:empty),
      name: "Elsewhere",
      color: "#e99537",
      lucide_icon: "tag"
    )
    original = @budget.budgeted_spending

    result = @function.call(
      "budgeted_spending" => 9999,
      "categories" => [ { "category" => other_family_category.id, "amount" => 10 } ]
    )

    assert_equal false, result[:success]
    assert_equal "invalid_params", result[:error]
    assert_equal original, @budget.reload.budgeted_spending
  end

  test "does not leave a bootstrapped budget behind when a later entry is invalid" do
    target = Date.current.beginning_of_month << 2
    assert_nil @family.budgets.find_by(start_date: target)

    result = @function.call(
      "month" => target.strftime("%Y-%m"),
      "budgeted_spending" => 1000,
      "categories" => [ { "category" => "No Such Category", "amount" => 10 } ]
    )

    assert_equal false, result[:success]
    assert_nil @family.budgets.find_by(start_date: target)
  end

  test "applies explicit parent amounts after subcategory updates regardless of order" do
    @budget.sync_budget_categories
    subcategory = categories(:subcategory)
    parent = subcategory.parent

    result = @function.call(
      "categories" => [
        { "category" => parent.id, "amount" => 1000 },
        { "category" => subcategory.id, "amount" => 300 }
      ]
    )

    assert_equal true, result[:success]

    sub_bc = @budget.budget_categories.find_by(category_id: subcategory.id)
    parent_bc = @budget.budget_categories.find_by(category_id: parent.id)
    assert_equal 300, sub_bc.reload.budgeted_spending
    assert_equal 1000, parent_bc.reload.budgeted_spending
  end

  test "explains that Uncategorized cannot be set directly" do
    @budget.sync_budget_categories

    result = @function.call(
      "categories" => [ { "category" => "Uncategorized", "amount" => 50 } ]
    )

    assert_equal false, result[:success]
    assert_equal "invalid_params", result[:error]
    assert_match(/cannot be set directly/i, result[:message])
  end

  test "rejects unknown category names" do
    result = @function.call(
      "categories" => [ { "category" => "No Such Category", "amount" => 10 } ]
    )

    assert_equal false, result[:success]
    assert_equal "invalid_params", result[:error]
    assert_match(/not found/i, result[:message])
  end

  test "rejects negative amounts" do
    result = @function.call("expected_income" => -5)

    assert_equal false, result[:success]
    assert_equal "invalid_params", result[:error]
  end

  test "rejects non-finite amounts" do
    @budget.sync_budget_categories

    [ Float::NAN, Float::INFINITY ].each do |value|
      result = @function.call("budgeted_spending" => value)
      assert_equal false, result[:success]
      assert_equal "invalid_params", result[:error]

      result = @function.call("categories" => [ { "category" => "Food & Drink", "amount" => value } ])
      assert_equal false, result[:success]
      assert_equal "invalid_params", result[:error]
    end
  end

  test "rejects malformed months" do
    result = @function.call("month" => "never", "budgeted_spending" => 1)

    assert_equal false, result[:success]
    assert_equal "invalid_params", result[:error]
  end

  test "rejects months outside the valid budget range" do
    far_future = (Date.current + 10.years).strftime("%Y-%m")

    result = @function.call("month" => far_future, "budgeted_spending" => 1)

    assert_equal false, result[:success]
    assert_equal "invalid_month", result[:error]
  end

  test "rejects calls with nothing to change" do
    result = @function.call({})

    assert_equal false, result[:success]
    assert_equal "no_changes", result[:error]
  end
end
