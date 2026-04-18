require "test_helper"

class BudgetCategoriesControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)

    @budget = budgets(:one)
    @family = @budget.family

    @parent_category = Category.create!(
      name: "Bills controller test",
      family: @family,
      color: "#4da568",
      lucide_icon: "house"
    )

    @electric_category = Category.create!(
      name: "Electric controller test",
      parent: @parent_category,
      family: @family
    )

    @water_category = Category.create!(
      name: "Water controller test",
      parent: @parent_category,
      family: @family
    )

    @parent_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @parent_category,
      budgeted_spending: 500,
      currency: "USD"
    )

    @electric_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @electric_category,
      budgeted_spending: 100,
      currency: "USD"
    )

    @water_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @water_category,
      budgeted_spending: 50,
      currency: "USD"
    )
  end

  test "index marks budget form values as privacy-sensitive" do
    get budget_budget_categories_path(@budget)

    assert_response :success
    assert_select "input##{dom_id(@parent_budget_category, :budgeted_spending)}"
    assert_select "##{dom_id(@parent_budget_category, :form)} .privacy-sensitive input##{dom_id(@parent_budget_category, :budgeted_spending)}"
    assert_select "##{dom_id(@budget, :uncategorized_budget_category_form)} .privacy-sensitive input[name='uncategorized']"
    assert_select "p.text-secondary.privacy-sensitive", text: /\/m avg/
  end

  test "updating a subcategory adjusts the parent budget by the same delta" do
    assert_changes -> { @parent_budget_category.reload.budgeted_spending.to_f }, from: 500.0, to: 550.0 do
      patch budget_budget_category_path(@budget, @electric_budget_category),
            params: { budget_category: { budgeted_spending: 150 } },
            as: :turbo_stream
    end

    assert_response :success
    assert_includes @response.body, dom_id(@parent_budget_category, :form)
  end

  test "manual parent budget remains on top of subcategory changes" do
    @parent_budget_category.update!(budgeted_spending: 900)

    assert_changes -> { @parent_budget_category.reload.budgeted_spending.to_f }, from: 900.0, to: 975.0 do
      patch budget_budget_category_path(@budget, @water_budget_category),
            params: { budget_category: { budgeted_spending: 125 } },
            as: :turbo_stream
    end
  end

  test "sibling subcategory budget form rerenders without a max allocation cap" do
    patch budget_budget_category_path(@budget, @electric_budget_category),
          params: { budget_category: { budgeted_spending: 125 } },
          as: :turbo_stream

    assert_response :success

    fragment = Nokogiri::HTML.fragment(@response.body)
    input = fragment.at_css("input##{dom_id(@water_budget_category, :budgeted_spending)}")

    assert_not_nil input
    assert_nil input["max"]
  end

  test "clearing a subcategory budget switches it back to shared and lowers the parent" do
    assert_changes -> { @parent_budget_category.reload.budgeted_spending.to_f }, from: 500.0, to: 400.0 do
      patch budget_budget_category_path(@budget, @electric_budget_category),
            params: { budget_category: { budgeted_spending: "" } },
            as: :turbo_stream
    end

    assert_equal 0.0, @electric_budget_category.reload.budgeted_spending.to_f
  end
end
