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

    # The toggle is stored state, so it travels with the summary; the carry
    # is a derived amount and stays with the others.
    assert_equal false, budget_category["rollover_enabled"]
    assert_not budget_category.key?("rolled_over_amount")
    assert_not budget_category.key?("rolled_over_amount_cents")
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

  test "show exposes the carry that makes available_to_spend exceed the allocation" do
    previous_budget = @family.budgets.create!(
      start_date: 6.months.ago.beginning_of_month.to_date,
      end_date: 6.months.ago.end_of_month.to_date,
      budgeted_spending: 3000,
      expected_income: 5000,
      currency: "USD"
    )
    previous_budget.budget_categories.create!(
      category: @category,
      budgeted_spending: 200,
      currency: "USD",
      rollover_enabled: true
    )
    @budget_category.update!(rollover_enabled: true)
    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!

    get api_v1_budget_category_url(@budget_category), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal true, response_data["rollover_enabled"]
    assert_equal 20_000, response_data["rolled_over_amount_cents"]

    # Without the field a client sees 700 available against a 500 allocation
    # and has nothing to account for the difference.
    assert_equal 50_000, response_data["budgeted_spending_cents"]
    assert_equal 70_000, response_data["available_to_spend_cents"]
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

  test "excludes another family member's personal budget category" do
    @family.update!(personal_budgets: true)

    other_member_budget = @family.budgets.create!(
      user: users(:family_member),
      start_date: 7.months.ago.beginning_of_month.to_date,
      end_date: 7.months.ago.end_of_month.to_date,
      budgeted_spending: 800,
      currency: "USD"
    )
    other_member_budget_category = other_member_budget.budget_categories.create!(
      category: @category,
      budgeted_spending: 200,
      currency: "USD"
    )

    get api_v1_budget_categories_url, headers: api_headers(@api_key)
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_not_includes response_data["budget_categories"].map { |budget_category| budget_category["id"] }, other_member_budget_category.id

    get api_v1_budget_category_url(other_member_budget_category), headers: api_headers(@api_key)
    assert_response :not_found
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

  # Every web surface that shows the carry recomputes on the way in, through
  # Budget.find_or_bootstrap. This endpoint reads the materialized column
  # straight, so it was the one place a carry left stale by a sync or a
  # recategorisation could still be served.
  test "index refreshes a stale carry rather than serving it" do
    earlier = Budget.find_or_bootstrap(@family, start_date: 3.months.ago.to_date, user: nil)
    earlier.update!(budgeted_spending: 3_000, expected_income: 5_000)
    earlier.budget_categories.find_by!(category: @category)
           .update!(budgeted_spending: 500, rollover_enabled: true)

    later = Budget.find_or_bootstrap(@family, start_date: 2.months.ago.to_date, user: nil)
    later.update!(budgeted_spending: 3_000, expected_income: 5_000)
    later.budget_categories.find_by!(category: @category)
         .update!(budgeted_spending: 500, rollover_enabled: true)

    # Simulate what a sync does: rewrite the stored carry behind the app's
    # back, the way a changed past month would leave it.
    later.budget_categories.find_by!(category: @category).update_column(:rolled_over_amount, 0)

    get api_v1_budget_categories_url, headers: api_headers(@api_key)

    assert_response :success
    assert_equal 500, later.budget_categories.find_by!(category: @category).reload[:rolled_over_amount]
  end
end
