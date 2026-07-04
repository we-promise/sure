require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @intro_user = users(:intro_user)
    @family = @user.family
  end

  test "dashboard" do
    get root_path
    assert_response :ok
  end

  test "update_preferences persists dashboard section layout height" do
    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: { net_worth_chart: { height: "compact" } } }
    }, as: :json

    assert_response :ok
    assert_equal "compact", @user.reload.dashboard_section_height("net_worth_chart")
  end

  test "update_preferences persists dashboard section width" do
    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: { cashflow_sankey: { col_span: "single" } } }
    }, as: :json

    assert_response :ok
    assert_equal "single", @user.reload.dashboard_section_width("cashflow_sankey")
  end

  test "update_preferences ignores malformed dashboard_section_layout without erroring" do
    previous_height = @user.reload.dashboard_section_height("net_worth_chart")

    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: "not-a-hash" }
    }, as: :json

    assert_response :ok
    assert_equal previous_height, @user.reload.dashboard_section_height("net_worth_chart")
  end

  test "dashboard memoizes income statement period totals while rendering" do
    income_statement = IncomeStatement.new(@family)
    IncomeStatement.stubs(:new).returns(income_statement)

    fake_expense_period_total = IncomeStatement::PeriodTotal.new(
      classification: "expense",
      total: 0,
      currency: @family.currency,
      category_totals: []
    )

    fake_income_period_total = IncomeStatement::PeriodTotal.new(
      classification: "income",
      total: 0,
      currency: @family.currency,
      category_totals: []
    )

    income_statement.expects(:build_period_total)
      .with(classification: "expense", period: kind_of(Period))
      .once
      .returns(fake_expense_period_total)

    income_statement.expects(:build_period_total)
      .with(classification: "income", period: kind_of(Period))
      .once
      .returns(fake_income_period_total)

    get root_path

    assert_response :ok
  end

  test "intro page requires guest role" do
    get intro_path

    assert_redirected_to root_path
    assert_equal "Intro is only available to guest users.", flash[:alert]
  end

  test "intro page is accessible for guest users" do
    sign_in @intro_user

    get intro_path

    assert_response :ok
  end

  test "dashboard renders sankey chart with subcategories" do
    # Create parent category with subcategory
    parent_category = @family.categories.create!(name: "Shopping", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Groceries", parent: parent_category, color: "#33FF57")

    # Create transactions using helper
    create_transaction(account: @family.accounts.first, name: "General shopping", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Grocery store", amount: 50, category: subcategory)

    get root_path
    assert_response :ok
    assert_select "[data-controller='sankey-chart']"
  end

  test "dashboard renders sankey chart zoom controls and stable node ids" do
    parent_category = @family.categories.create!(name: "Shopping", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Groceries", parent: parent_category, color: "#33FF57")

    create_transaction(account: @family.accounts.first, name: "General shopping", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Grocery store", amount: 50, category: subcategory)

    get root_path

    assert_response :ok
    assert_select "[data-sankey-chart-target='zoomOutButton'][hidden]", count: 2

    chart = css_select("[data-controller='sankey-chart']").first
    sankey_data = JSON.parse(chart["data-sankey-chart-data-value"])

    assert_includes sankey_data.fetch("nodes").map { |node| node.fetch("id") }, "cash_flow_node"
    assert sankey_data.fetch("nodes").any? { |node| node.fetch("id").start_with?("expense_") }
  end

  test "dashboard renders money flow widget" do
    get root_path

    assert_response :ok
    assert_select "[data-controller='bar-chart']"
  end

  test "dashboard scopes money flow widget to selected month and accounts" do
    # Dedicated account (rather than @family.accounts.first) so fixture
    # transactions on other accounts can't skew the computed totals.
    account = @family.accounts.create!(name: "Money Flow Test Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    selected_month = 1.month.ago.beginning_of_month.to_date
    create_transaction(account: account, name: "Groceries", amount: 50, date: selected_month + 1.day)
    create_transaction(account: account, name: "Paycheck", amount: -200, date: selected_month + 2.days)

    get root_path, params: {
      money_flow_month: selected_month.iso8601,
      money_flow_account_ids: [ account.id ]
    }

    assert_response :ok
    bars = money_flow_bars

    assert_equal 3, bars.size
    highlighted = bars.find { |bar| bar["highlighted"] }
    assert_equal selected_month.iso8601, highlighted["date"]
    assert_equal 50.0, highlighted["expense"]
    assert_equal 200.0, highlighted["income"]
  end

  test "dashboard money flow widget ignores account ids not accessible to the current user" do
    other_family = Family.create!(name: "Other Family", currency: "USD")
    other_account = other_family.accounts.create!(name: "Other Family Checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: other_account, name: "Not mine", amount: 999)

    get root_path
    default_bars = money_flow_bars

    get root_path, params: { money_flow_account_ids: [ other_account.id ] }

    assert_response :ok
    filtered_bars = money_flow_bars

    # An id outside the current user's accessible accounts is dropped entirely
    # (money_flow_account_ids_param intersects against accessible ids), so the
    # widget falls back to its unfiltered "all accessible accounts" state
    # rather than scoping to a foreign account or erroring.
    assert_equal default_bars, filtered_bars
  end

  test "dashboard money flow widget excludes accounts ineligible for cashflow totals from its account filter" do
    excluded_account = @family.accounts.create!(
      name: "Excluded From Reports",
      currency: @family.currency,
      balance: 0,
      exclude_from_reports: true,
      accountable: Depository.new
    )

    get root_path

    assert_response :ok
    assert_select "input[type='checkbox'][value=?]", excluded_account.id.to_s, count: 0
  end

  test "dashboard money flow widget ignores account ids excluded from cashflow totals" do
    excluded_account = @family.accounts.create!(
      name: "Excluded From Reports",
      currency: @family.currency,
      balance: 0,
      exclude_from_reports: true,
      accountable: Depository.new
    )
    create_transaction(account: excluded_account, name: "Not counted", amount: 999)

    get root_path
    default_bars = money_flow_bars

    get root_path, params: { money_flow_account_ids: [ excluded_account.id ] }

    assert_response :ok
    filtered_bars = money_flow_bars

    # An account excluded from reports is visible/accessible but not eligible
    # for cashflow totals, so selecting only it must fall back to the
    # unfiltered state instead of silently computing to zero.
    assert_equal default_bars, filtered_bars
  end

  test "dashboard clamps a future money flow month instead of erroring" do
    get root_path, params: { money_flow_month: 1.month.from_now.beginning_of_month.iso8601 }

    assert_response :ok
    bars = money_flow_bars

    assert_equal Date.current.beginning_of_month.iso8601, bars.last["date"]
  end

  test "dashboard money flow income/expense links exclude pending transactions" do
    get root_path

    assert_response :ok
    assert_select "a[href*='q%5Btypes%5D%5B%5D=income'][href*='q%5Bstatus%5D%5B%5D=confirmed']"
    assert_select "a[href*='q%5Btypes%5D%5B%5D=expense'][href*='q%5Bstatus%5D%5B%5D=confirmed']"
  end

  test "changelog" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      get changelog_path
      assert_response :ok
    end
  end

  test "changelog with nil release notes" do
    # Mock the GitHub provider to return nil (simulating API failure or no releases)
    github_provider = mock
    github_provider.expects(:fetch_latest_release_notes).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Release notes unavailable"
    assert_select "a[href='https://github.com/we-promise/sure/releases']"
  end

  test "changelog with incomplete release notes" do
    # Mock the GitHub provider to return incomplete data (missing some fields)
    github_provider = mock
    incomplete_data = {
      avatar: nil,
      username: "maybe-finance",
      name: "Test Release",
      published_at: nil,
      body: nil
    }
    github_provider.expects(:fetch_latest_release_notes).returns(incomplete_data)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Test Release"
    # Should not crash even with nil values
  end

  private
    def money_flow_bars
      JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
    end
end
