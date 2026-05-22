# frozen_string_literal: true

require "test_helper"

class Api::V1::BudgetCategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @budget = @family.budgets.create!(
      start_date: 5.months.ago.beginning_of_month.to_date,
      end_date: 5.months.ago.end_of_month.to_date,
      budgeted_spending: 3000,
      expected_income: 5000,
      currency: "USD"
    )
    @category = categories(:food_and_drink)
    @budget_category = @budget.budget_categories.create!(
      category: @category,
      budgeted_spending: 500,
      currency: "USD"
    )

    other_family = families(:empty)
    other_category = other_family.categories.create!(name: "Other Food", color: "#123456")
    other_budget = other_family.budgets.create!(
      start_date: 6.months.ago.beginning_of_month.to_date,
      end_date: 6.months.ago.end_of_month.to_date,
      budgeted_spending: 1000,
      expected_income: 2000,
      currency: "USD"
    )
    @other_budget_category = other_budget.budget_categories.create!(
      category: other_category,
      budgeted_spending: 100,
      currency: "USD"
    )
  end

  test "lists budget categories scoped to the current family" do
    get api_v1_budget_categories_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("budget_categories")
    assert response_data.key?("pagination")
    assert_includes response_data["budget_categories"].map { |budget_category| budget_category["id"] }, @budget_category.id
    assert_not_includes response_data["budget_categories"].map { |budget_category| budget_category["id"] }, @other_budget_category.id

    budget_category = response_data["budget_categories"].find { |category| category["id"] == @budget_category.id }
    assert_kind_of Integer, budget_category["budgeted_spending_cents"]
    assert_not budget_category.key?("actual_spending")
    assert_not budget_category.key?("actual_spending_cents")
    assert_not budget_category.key?("available_to_spend")
    assert_not budget_category.key?("available_to_spend_cents")
  end

  test "shows a budget category" do
    get api_v1_budget_category_url(@budget_category), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @budget_category.id, response_data["id"]
    assert_equal @budget.id, response_data["budget_id"]
    assert_equal @category.id, response_data.dig("category", "id")
    assert_kind_of Integer, response_data["budgeted_spending_cents"]
    assert_kind_of Integer, response_data["actual_spending_cents"]
    assert_kind_of Integer, response_data["available_to_spend_cents"]
  end

  test "returns not found for another family's budget category" do
    get api_v1_budget_category_url(@other_budget_category), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed budget category id" do
    get api_v1_budget_category_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters budget categories by budget_id" do
    get api_v1_budget_categories_url,
        params: { budget_id: @budget.id },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["budget_categories"].map { |budget_category| budget_category["id"] }, @budget_category.id
  end

  test "filters budget categories by category_id" do
    get api_v1_budget_categories_url,
        params: { category_id: @category.id },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["budget_categories"].map { |budget_category| budget_category["id"] }, @budget_category.id
  end

  test "rejects malformed budget_id filter" do
    get api_v1_budget_categories_url, params: { budget_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filters" do
    get api_v1_budget_categories_url, params: { start_date: "03/01/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "requires authentication" do
    get api_v1_budget_categories_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "mobile",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_budget_categories_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end
end
