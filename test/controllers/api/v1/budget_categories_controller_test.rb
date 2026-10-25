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

  test "lists budget categories scoped to the current family without derived amounts" do
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

  test "index filtered by budget_id carries the derived amounts show returns" do
    create_spending(category: @category, amount: 120)

    get api_v1_budget_categories_url,
        params: { budget_id: @budget.id, per_page: 100 },
        headers: api_headers(@api_key)

    assert_response :success
    listed = JSON.parse(response.body)["budget_categories"].find { |line| line["id"] == @budget_category.id }

    get api_v1_budget_category_url(@budget_category), headers: api_headers(@api_key)
    assert_response :success
    shown = JSON.parse(response.body)

    assert_equal 12_000, listed["actual_spending_cents"]
    %w[
      actual_spending actual_spending_cents
      rolled_over_amount rolled_over_amount_cents
      available_to_spend available_to_spend_cents
    ].each do |field|
      assert_equal shown[field], listed[field], "index and show disagree on #{field}"
    end
  end

  test "index filtered by budget_id computes the budget's totals once for all its lines" do
    # Counts query-cache hits too, so a totals query repeated per line is
    # caught even when the cache answers it.
    list = lambda do
      queries = []
      callback = lambda do |*, payload|
        queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get api_v1_budget_categories_url,
            params: { budget_id: @budget.id, per_page: 100 },
            headers: api_headers(@api_key)
      end
      assert_response :success
      queries
    end

    list.call
    few_lines = list.call.size

    4.times { |i| @family.categories.create!(name: "Extra API line #{i}", color: "#123456") }
    list.call
    many_lines_queries = list.call
    many_lines = JSON.parse(response.body)["budget_categories"]

    assert_operator many_lines.size, :>=, 5
    assert many_lines.all? { |line| line.key?("actual_spending_cents") }
    assert_equal few_lines, many_lines_queries.size
  end

  test "index filtered by budget_id adds lines for categories created after the budget" do
    new_category = @family.categories.create!(name: "Added after the budget", color: "#654321")

    get api_v1_budget_categories_url,
        params: { budget_id: @budget.id, per_page: 100 },
        headers: api_headers(@api_key)

    assert_response :success
    line = JSON.parse(response.body)["budget_categories"].find { |bc| bc.dig("category", "id") == new_category.id }
    assert line, "Expected a line for the new category"
    assert_equal 0, line["budgeted_spending_cents"]
    assert_equal 0, line["actual_spending_cents"]
    assert @budget.budget_categories.exists?(category: new_category)
  end

  test "index still lists when a concurrent request synced the same line first" do
    duplicate = @budget.budget_categories.build(category: @category)
    duplicate.errors.add(:budget_id, :taken)
    Budget.any_instance.stubs(:sync_budget_categories).raises(ActiveRecord::RecordInvalid.new(duplicate))

    get api_v1_budget_categories_url, params: { budget_id: @budget.id }, headers: api_headers(@api_key)

    assert_response :success
    assert_includes JSON.parse(response.body)["budget_categories"].map { |line| line["id"] }, @budget_category.id
  end

  test "index without budget_id neither syncs lines nor computes actuals" do
    new_category = @family.categories.create!(name: "Not synced unfiltered", color: "#654321")

    get api_v1_budget_categories_url, headers: api_headers(@api_key)

    assert_response :success
    assert_not @budget.budget_categories.exists?(category: new_category)
    assert JSON.parse(response.body)["budget_categories"].none? { |line| line.key?("actual_spending_cents") }
  end

  test "index does not add lines to another member's shared budget" do
    @family.update!(personal_budgets: true)
    owner = users(:family_member)
    shared_budget = @family.budgets.create!(
      user: owner,
      start_date: 7.months.ago.beginning_of_month.to_date,
      end_date: 7.months.ago.end_of_month.to_date,
      budgeted_spending: 800,
      currency: "USD"
    )
    shared_budget.budget_categories.create!(category: @category, budgeted_spending: 200, currency: "USD")
    BudgetShare.create!(owner: owner, viewer: @user, permission: "read_only")
    new_category = @family.categories.create!(name: "Owner has not opened it", color: "#654321")

    get api_v1_budget_categories_url,
        params: { budget_id: shared_budget.id, per_page: 100 },
        headers: api_headers(@api_key)

    assert_response :success
    lines = JSON.parse(response.body)["budget_categories"]
    assert_equal [ @category.id ], lines.map { |line| line.dig("category", "id") }
    assert lines.first.key?("actual_spending_cents")
    assert_not shared_budget.budget_categories.exists?(category: new_category)
  end

  test "index with another family's budget_id returns nothing and writes nothing" do
    other_budget = @other_budget_category.budget
    other_budget.family.categories.create!(name: "Other family new", color: "#654321")

    assert_no_difference "BudgetCategory.count" do
      get api_v1_budget_categories_url,
          params: { budget_id: other_budget.id },
          headers: api_headers(@api_key)
    end

    assert_response :success
    assert_empty JSON.parse(response.body)["budget_categories"]
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

  test "show exposes ring-fenced child carry included in parent availability" do
    parent_category = @family.categories.create!(name: "Parent rollover API", color: "#123456")
    child_category = @family.categories.create!(name: "Child rollover API", parent: parent_category)
    previous_budget = @family.budgets.create!(
      start_date: 6.months.ago.beginning_of_month.to_date,
      end_date: 6.months.ago.end_of_month.to_date,
      budgeted_spending: 80,
      expected_income: 100,
      currency: "USD"
    )
    previous_budget.budget_categories.create!(
      category: parent_category, budgeted_spending: 80, currency: "USD"
    )
    previous_budget.budget_categories.create!(
      category: child_category, budgeted_spending: 80, currency: "USD", rollover_enabled: true
    )
    parent_budget_category = @budget.budget_categories.create!(
      category: parent_category, budgeted_spending: 100, currency: "USD"
    )
    @budget.budget_categories.create!(
      category: child_category, budgeted_spending: 100, currency: "USD", rollover_enabled: true
    )

    get api_v1_budget_category_url(parent_budget_category), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal 10_000, response_data["budgeted_spending_cents"]
    assert_equal 8_000, response_data["rolled_over_amount_cents"]
    assert_equal 18_000, response_data["available_to_spend_cents"]
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

  private

    def create_spending(category:, amount:)
      Entry.create!(
        account: accounts(:depository),
        entryable: Transaction.create!(category: category),
        date: @budget.start_date + 10.days,
        name: "API budget spending",
        amount: amount,
        currency: "USD"
      )
    end
end
