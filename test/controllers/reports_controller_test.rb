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

    expected_end   = Date.current.end_of_month
    expected_start = (expected_end + 1.day - 6.months).beginning_of_month

    # Should show exactly 6 months, not 7
    assert_equal 6, (expected_end.year * 12 + expected_end.month) - (expected_start.year * 12 + expected_start.month) + 1

    # Page should include both boundary months
    assert_includes @response.body, expected_start.strftime("%b %Y")
    assert_includes @response.body, expected_end.strftime("%b %Y")

    # Page should NOT include the months immediately outside the window
    prev_month = expected_start - 1.month
    next_month = expected_end + 1.month
    assert_not_includes @response.body, prev_month.strftime("%b %Y")
    assert_not_includes @response.body, next_month.strftime("%b %Y")
  end

  test "last 6 months default start date is consistent with navigation" do
    # First load (no params) should produce the same start/end as the navigation arrows would
    get reports_path(period_type: :last_6_months)
    assert_response :ok

    expected_end   = Date.current.end_of_month
    expected_start = (expected_end + 1.day - 6.months).beginning_of_month

    # Navigate forward from one window back — should land on the same default window
    prev_start = expected_start - 6.months
    prev_end   = prev_start + 6.months - 1.day

    get reports_path(period_type: :last_6_months, start_date: prev_start, end_date: prev_end)
    assert_response :ok

    # The next-window link should point to the same dates as the default
    assert_select "a[href=?]",
      reports_path(period_type: :last_6_months, start_date: expected_start, end_date: expected_end)
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

  test "index avoids residual category lazy loads" do
    account = accounts(:depository)

    4.times do |idx|
      parent = @family.categories.create!(
        name: "Reports Parent #{idx}",
        color: "#000000",
        lucide_icon: "folder"
      )
      child = @family.categories.create!(
        name: "Reports Child #{idx}",
        color: "#111111",
        lucide_icon: "folder",
        parent: parent
      )
      entry = account.entries.create!(
        name: "Reports transaction #{idx}",
        date: Date.current,
        amount: 10 + idx,
        currency: "USD",
        entryable: Transaction.new(
          category: child,
          kind: "standard"
        )
      )
      assert entry.persisted?
    end

    queries = capture_sql_queries { get reports_path(period_type: :monthly) }

    assert_response :ok
    assert_empty queries.grep(/SELECT "categories"\.\* FROM "categories" WHERE "categories"\."id" = \$1 LIMIT \$2/)
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

  test "export transactions with API key does not inherit web session impersonation" do
    support_user = users(:sure_support_staff)
    support_user.api_keys.active.destroy_all
    token_value = ApiKey.generate_secure_key
    export_credential = support_user.api_keys.build(
      name: "Support Export Credential",
      scopes: [ "read" ],
      source: "web"
    )
    export_credential.key = token_value
    export_credential.save!

    impersonation_session = impersonation_sessions(:in_progress)
    impersonated_user = impersonation_session.impersonated
    leaked_category = impersonated_user.family.categories.create!(
      name: "Impersonated Export Leak Probe"
    )
    impersonated_account = impersonated_user.finance_accounts.first
    assert_not_nil impersonated_account, "Test setup failed: impersonated user has no finance account"

    create_transaction(
      account: impersonated_account,
      name: "Impersonated export leak probe",
      date: Date.current,
      amount: 123.45,
      category: leaked_category
    )

    support_user.sessions.destroy_all
    support_user.sessions.create!(
      user_agent: "Browser session",
      ip_address: "127.0.0.1",
      active_impersonator_session: impersonation_session
    )

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current,
      api_key: token_value
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    assert_no_match /Impersonated Export Leak Probe/, @response.body
  end

  test "export transactions with API key rejects deactivated user" do
    user = users(:family_admin)
    user.api_keys.active.destroy_all
    token_value = ApiKey.generate_secure_key
    export_access = user.api_keys.build(
      name: "Inactive User Export Credential",
      scopes: [ "read" ],
      source: "web"
    )
    export_access.key = token_value
    export_access.save!
    user.update_column(:active, false)

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      api_key: token_value
    )

    assert_response :unauthorized
    assert_match /Invalid or expired API key/, @response.body
  ensure
    user&.update_column(:active, true)
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

  test "filter_account_id cannot bypass finance account scoping" do
    member = users(:family_member)
    allowed_account = accounts(:depository)
    private_account = accounts(:investment)

    assert_includes member.finance_accounts.pluck(:id), allowed_account.id
    assert_not_includes member.finance_accounts.pluck(:id), private_account.id

    leaked_category = @family.categories.create!(name: "LEAKED_REPORTS_CATEGORY", color: "#737373", lucide_icon: "circle")
    allowed_category = @family.categories.create!(name: "ALLOWED_REPORTS_CATEGORY", color: "#737373", lucide_icon: "circle")

    private_account.entries.create!(
      name: "Admin-only spend",
      date: Date.current,
      amount: -25,
      currency: "USD",
      entryable: Transaction.new(category: leaked_category, kind: "standard")
    )
    allowed_account.entries.create!(
      name: "Shared checking spend",
      date: Date.current,
      amount: -15,
      currency: "USD",
      entryable: Transaction.new(category: allowed_category, kind: "standard")
    )

    sign_in member

    get reports_path(period_type: :monthly, filter_account_id: private_account.id)
    refute_includes @response.body, "LEAKED_REPORTS_CATEGORY"
    refute_includes @response.body, "ALLOWED_REPORTS_CATEGORY"

    get reports_path(period_type: :monthly, filter_account_id: allowed_account.id)
    assert_includes @response.body, "ALLOWED_REPORTS_CATEGORY"
    refute_includes @response.body, "LEAKED_REPORTS_CATEGORY"
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

  test "export transactions excludes tax-advantaged account transactions" do
    taxable_category = @family.categories.create!(name: "Export Taxable Income", color: "#111111")
    retirement_category = @family.categories.create!(name: "Export Retirement Income", color: "#222222")
    taxable_account = @family.accounts.create!(
      owner: @user,
      name: "Export Taxable Brokerage",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "brokerage")
    )
    retirement_account = @family.accounts.create!(
      owner: @user,
      name: "Export 401k",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "401k")
    )

    create_transaction(account: taxable_account, name: "Taxable export dividend", amount: -100, category: taxable_category)
    create_transaction(account: retirement_account, name: "401k export dividend", amount: -200, category: retirement_category)

    get export_transactions_reports_path(
      format: :csv,
      period_type: :monthly,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    assert_match /Export Taxable Income/, @response.body
    assert_no_match /Export Retirement Income/, @response.body
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

  test "index excludes tax-advantaged account transactions from activity breakdown" do
    @family.accounts.each { |account| account.entries.destroy_all }

    taxable_category = @family.categories.create!(name: "Reports Taxable Income", color: "#111111")
    retirement_category = @family.categories.create!(name: "Reports Retirement Income", color: "#222222")
    taxable_account = @family.accounts.create!(
      owner: @user,
      name: "Reports Taxable Brokerage",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "brokerage")
    )
    retirement_account = @family.accounts.create!(
      owner: @user,
      name: "Reports 401k",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "401k")
    )

    create_transaction(account: taxable_account, name: "Taxable dividend", amount: -100, category: taxable_category)
    create_transaction(account: retirement_account, name: "401k dividend", amount: -200, category: retirement_category)
    create_trade(securities(:aapl), account: taxable_account, qty: 1, date: Date.current, price: 100)
    create_trade(securities(:aapl), account: retirement_account, qty: 1, date: Date.current, price: 200)

    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "tr[data-category='category-#{taxable_category.id}']", text: /Reports Taxable Income/
    assert_select "tr[data-category='category-#{retirement_category.id}']", count: 0

    other_investments_row = css_select("tr[data-category='category-other_investments']").first
    assert_not_nil other_investments_row
    assert_match(/#{Regexp.escape(Category.other_investments.name)}/, other_investments_row.text)
    assert_match(/#{Regexp.escape(I18n.t("reports.transactions_breakdown.table.entries", count: 1))}/, other_investments_row.text)
    assert_match(/\$100\.00/, other_investments_row.text)
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
