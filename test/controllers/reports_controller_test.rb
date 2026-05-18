require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "index renders successfully" do
    get reports_path
    assert_response :ok
  end

  test "index with monthly period" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h1", text: I18n.t("reports.index.title")
  end

  test "index with quarterly period" do
    get reports_path(period_type: :quarterly)
    assert_response :ok
  end

  test "index with ytd period" do
    get reports_path(period_type: :ytd)
    assert_response :ok
  end

  test "index with custom period and date range" do
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.to_date.to_s,
      end_date: Date.current.to_s
    )
    assert_response :ok
  end

  test "index with last 6 months period" do
    get reports_path(period_type: :last_6_months)
    assert_response :ok
  end

  test "index shows empty state when no transactions" do
    # Delete all transactions for the family by deleting from accounts
    @family.accounts.each { |account| account.entries.destroy_all }

    get reports_path
    assert_response :ok
    assert_select "h3", text: I18n.t("reports.empty_state.title")
  end

  test "index with budget performance for current month" do
    # Create a budget for current month
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    category = @family.categories.expenses.first

    # Fail fast if test setup is incomplete
    assert_not_nil category, "Test setup failed: no expense category found for family"
    assert_not_nil budget, "Test setup failed: budget could not be created or found"

    # Find or create budget category to avoid duplicate errors
    budget_category = budget.budget_categories.find_or_initialize_by(category: category)
    budget_category.budgeted_spending = Money.new(50000, @family.currency)
    budget_category.save!

    get reports_path(period_type: :monthly)
    assert_response :ok
  end

  test "index calculates summary metrics correctly" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h3", text: I18n.t("reports.summary.total_income")
    assert_select "h3", text: I18n.t("reports.summary.total_expenses")
    assert_select "h3", text: I18n.t("reports.summary.net_savings")
  end

  test "index builds trends data" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h2", text: I18n.t("reports.trends.title")
    assert_select "thead" do
      assert_select "th", text: I18n.t("reports.trends.month")
    end
  end

  test "index handles invalid date parameters gracefully" do
    get reports_path(
      period_type: :custom,
      start_date: "invalid-date",
      end_date: "also-invalid"
    )
    assert_response :ok # Should not crash, uses defaults
  end

  test "index swaps dates when end_date is before start_date" do
    start_date = Date.current
    end_date = 1.month.ago.to_date

    get reports_path(
      period_type: :custom,
      start_date: start_date.to_s,
      end_date: end_date.to_s
    )

    assert_response :ok
    assert_equal I18n.t("reports.invalid_date_range"), flash[:alert]
    assert_includes @response.body, end_date.strftime("%b %Y")
    assert_includes @response.body, start_date.strftime("%b %Y")
  end

  test "spending patterns returns data when expense transactions exist" do
    # Create expense category
    expense_category = @family.categories.create!(
      name: "Test Groceries"
    )

    # Create account
    account = @family.accounts.first

    # Create expense transaction on a weekday (Monday)
    weekday_date = Date.current.beginning_of_month + 2.days
    weekday_date = weekday_date.next_occurring(:monday)

    entry = account.entries.create!(
      name: "Grocery shopping",
      date: weekday_date,
      amount: 50.00,
      currency: "USD",
      entryable: Transaction.new(
        category: expense_category,
        kind: "standard"
      )
    )

    # Create expense transaction on a weekend (Saturday)
    weekend_date = weekday_date.next_occurring(:saturday)

    weekend_entry = account.entries.create!(
      name: "Weekend shopping",
      date: weekend_date,
      amount: 75.00,
      currency: "USD",
      entryable: Transaction.new(
        category: expense_category,
        kind: "standard"
      )
    )

    get reports_path(period_type: :monthly)
    assert_response :ok

    # Verify spending patterns shows data (not the "no data" message)
    assert_select ".text-center.py-8.text-subdued", { text: /No spending data/, count: 0 }, "Should not show 'No spending data' message when transactions exist"
  end

  test "export transactions with API key authentication" do
    # Use an active API key with read permissions
    api_key = api_keys(:active_key)

    # Make sure the API key has the correct source
    api_key.update!(source: "web") unless api_key.source == "web"

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current,
      api_key: api_key.plain_key
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    assert_match /Category/, @response.body
  end

  test "export transactions with invalid API key" do
    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      api_key: "invalid_key"
    )

    assert_response :unauthorized
    assert_match /Invalid or expired API key/, @response.body
  end

  test "export transactions without API key uses session auth" do
    # Should use normal session-based authentication
    # The setup already signs in @user = users(:family_admin)
    assert_not_nil @user, "User should be set in test setup"
    assert_not_nil @family, "Family should be set in test setup"

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current
    )

    assert_response :ok, "Export should work with session auth. Response: #{@response.body}"
    assert_equal "text/csv", @response.media_type
  end

  test "export transactions swaps dates when end_date is before start_date" do
    start_date = Date.current
    end_date = 1.month.ago.to_date

    get export_transactions_reports_path(
      format: :csv,
      period_type: :custom,
      start_date: start_date.to_s,
      end_date: end_date.to_s
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    # Verify the CSV content is generated (should not crash)
    assert_not_nil @response.body
  end

  test "index groups transactions by parent and subcategories" do
    # Create parent category with subcategories
    parent_category = @family.categories.create!(name: "Entertainment", color: "#FF5733")
    subcategory_movies = @family.categories.create!(name: "Movies", parent: parent_category, color: "#33FF57")
    subcategory_games = @family.categories.create!(name: "Games", parent: parent_category, color: "#5733FF")

    # Create transactions using helper
    create_transaction(account: @family.accounts.first, name: "Cinema ticket", amount: 15, category: subcategory_movies)
    create_transaction(account: @family.accounts.first, name: "Video game", amount: 60, category: subcategory_games)

    get reports_path(period_type: :monthly)
    assert_response :ok

    # Parent category
    assert_select "tr[data-category='category-#{parent_category.id}']", text: /^Entertainment/

    # Subcategories
    assert_select "tr[data-category='category-#{subcategory_movies.id}']", text: /^Movies/
    assert_select "tr[data-category='category-#{subcategory_games.id}']", text: /^Games/
  end

  test "monthly period navigation shows previous month link" do
    get reports_path(period_type: :monthly)
    assert_response :ok

    prev_start = Date.current.beginning_of_month - 1.month
    prev_end = prev_start.end_of_month
    assert_select "a[href=?]", reports_path(period_type: :monthly, start_date: prev_start, end_date: prev_end)
  end

  test "monthly period navigation disables next arrow on current month" do
    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "button[disabled][aria-label=?]", I18n.t("reports.index.next_period")
  end

  test "monthly period navigation shows next month link on past month" do
    past_start = Date.current.beginning_of_month - 2.months
    past_end = past_start.end_of_month
    get reports_path(period_type: :monthly, start_date: past_start, end_date: past_end)
    assert_response :ok

    next_start = past_start + 1.month
    next_end = next_start.end_of_month
    assert_select "a[href=?]", reports_path(period_type: :monthly, start_date: next_start, end_date: next_end)
  end

  test "last 6 months next window extends to current month end when crossing boundary" do
    start_date = Date.current.beginning_of_month - 12.months
    end_date = start_date + 6.months - 1.day

    get reports_path(period_type: :last_6_months, start_date: start_date, end_date: end_date)
    assert_response :ok

    candidate_start = start_date.beginning_of_month + 6.months
    if candidate_start + 6.months >= Date.current.beginning_of_month
      expected_next_end   = Date.current.end_of_month
      expected_next_start = (expected_next_end + 1.day - 6.months).beginning_of_month
    else
      expected_next_start = candidate_start
      expected_next_end   = expected_next_start + 6.months - 1.day
    end

    assert_select "a[href=?]",
      reports_path(period_type: :last_6_months, start_date: expected_next_start, end_date: expected_next_end)
  end

  test "quarterly period navigation shows previous and next quarter links" do
    get reports_path(period_type: :quarterly)
    assert_response :ok

    prev_start = (Date.current.beginning_of_quarter - 1.day).beginning_of_quarter
    prev_end = prev_start.end_of_quarter
    assert_select "a[href=?]", reports_path(period_type: :quarterly, start_date: prev_start, end_date: prev_end)

    # Also verify a past quarter shows an enabled next-quarter link
    get reports_path(period_type: :quarterly, start_date: prev_start, end_date: prev_end)
    assert_response :ok

    next_start = prev_start.next_quarter.beginning_of_quarter
    next_end   = next_start.end_of_quarter
    assert_select "a[href=?]", reports_path(period_type: :quarterly, start_date: next_start, end_date: next_end)
  end

  test "custom period hides period display" do
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.to_date,
      end_date: Date.current
    )
    assert_response :ok

    prev_start = 1.month.ago.to_date.beginning_of_month - 1.month
    next_start = 1.month.ago.to_date.beginning_of_month + 1.month
    assert_select "a[href*=?]", "start_date=#{prev_start}", count: 0
    assert_select "a[href*=?]", "start_date=#{next_start}", count: 0
  end

  test "ytd period navigation shows previous year link" do
    get reports_path(period_type: :ytd)
    assert_response :ok

    prev_year  = Date.current.year - 1
    prev_start = Date.new(prev_year, 1, 1)
    prev_end   = Date.new(prev_year, 12, 31)
    assert_select "a[href=?]", reports_path(period_type: :ytd, start_date: prev_start, end_date: prev_end)
  end

  test "ytd period navigation disables next arrow on current year" do
    get reports_path(period_type: :ytd)
    assert_response :ok

    assert_select "button[disabled][aria-label=?]", I18n.t("reports.index.next_period")
  end
end
