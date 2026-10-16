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

  test "dashboard renders the net worth chart as drag-selectable, opting it out of card drag-and-drop" do
    get root_path

    assert_response :ok
    assert_select "#netWorthChart[data-time-series-chart-selectable-value='true'][draggable='false']"
  end

  test "dashboard has no chat sidebar or toggle when the assistant type is mcp_only" do
    get root_path
    assert_select "#chat-container", count: 1
    assert_select "[data-action='app-layout#toggleRightSidebar']", count: 1

    @family.update!(assistant_type: "mcp_only")
    get root_path

    assert_response :ok
    assert_select "#chat-container", count: 0
    assert_select "[data-action='app-layout#toggleRightSidebar']", count: 0
    assert_select "a[href='#{chats_path}']", count: 0
  end

  test "inactive user's existing session is revoked" do
    session_record = @user.sessions.order(:created_at).last
    @user.update_column(:active, false)

    get root_path

    assert_redirected_to new_session_path
    assert_not Session.exists?(session_record.id)
  end

  test "update_preferences persists dashboard section layout height" do
    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: { net_worth_chart: { height: "compact" } } }
    }, as: :json

    assert_response :ok
    assert_equal "compact", @user.reload.dashboard_section_height("net_worth_chart")
  end

  test "update_preferences saves the preview Sankey grouping and ignores unknown ones" do
    patch "/dashboard/preferences", params: { preferences: { cashflow_sankey_group_by: "account" } }, as: :json
    assert_response :success
    assert_equal "account", @user.reload.cashflow_sankey_group_by

    patch "/dashboard/preferences", params: { preferences: { cashflow_sankey_group_by: "merchant" } }, as: :json
    assert_equal "account", @user.reload.cashflow_sankey_group_by
  end

  test "update_preferences persists dashboard section width" do
    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: { cashflow_sankey: { col_span: "single" } } }
    }, as: :json

    assert_response :ok
    assert_equal "single", @user.reload.dashboard_section_width("cashflow_sankey")
  end

  test "the Customize button is an icon named for screen readers" do
    get root_path

    assert_select "a[href='#{root_path(customize: true)}']", count: 2 do |links|
      links.each do |link|
        assert_equal I18n.t("pages.dashboard.customize.start"), link["aria-label"]
        assert_empty link.text.strip
      end
    end
  end

  test "dashboard leaves hidden sections out" do
    @user.update_dashboard_section_hidden("net_worth_chart", true)

    get root_path

    assert_response :ok
    assert_select "section[data-section-key='net_worth_chart']", count: 0
    assert_select "section[data-section-key='balance_sheet']"
    assert_select "form[action='#{dashboard_section_hidden_path("balance_sheet")}']", count: 0
  end

  test "customize mode offers hiding shown sections and re-adding hidden ones" do
    @user.update_dashboard_section_hidden("net_worth_chart", true)

    get root_path(customize: true)

    assert_response :ok
    assert_select "section[data-section-key='balance_sheet'] form[action='#{dashboard_section_hidden_path("balance_sheet")}'] input[name='hidden'][value='true']"
    assert_select "form[action='#{dashboard_section_hidden_path("net_worth_chart")}'] input[name='hidden'][value='false']"
    assert_select "button", text: I18n.t("pages.dashboard.net_worth_chart.title")
  end

  test "customize mode does not offer back a hidden section with nothing to show" do
    @user.update_dashboard_section_hidden("investment_summary", true)
    InvestmentStatement.any_instance.stubs(:investment_accounts).returns(Account.none)

    get root_path(customize: true)

    assert_response :ok
    assert_select "form[action='#{dashboard_section_hidden_path("investment_summary")}']", count: 0
  end

  test "customize mode offers back a hidden insights feed only while it has insights" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @user.update_dashboard_section_hidden("insights_feed", true)

    get root_path(customize: true)
    assert_select "form[action='#{dashboard_section_hidden_path("insights_feed")}']"

    @family.insights.update_all(status: "dismissed")

    get root_path(customize: true)
    assert_select "form[action='#{dashboard_section_hidden_path("insights_feed")}']", count: 0
  end

  # A user who never reordered has only the default order saved, which leaves
  # out widgets like money_flow that render after it.
  test "update_preferences keeps a hidden widget's place when the saved order never listed it" do
    @user.update_dashboard_section_hidden("money_flow", true)

    patch "/dashboard/preferences", params: {
      preferences: { section_order: %w[cashflow_sankey outflows_donut net_worth_chart balance_sheet spending_trend investment_summary] }
    }, as: :json

    assert_response :ok
    assert_equal %w[cashflow_sankey outflows_donut net_worth_chart balance_sheet money_flow spending_trend investment_summary],
      @user.reload.dashboard_section_order
  end

  test "update_section_hidden hides and re-adds a section" do
    patch dashboard_section_hidden_path("net_worth_chart"), params: { hidden: true }

    assert_redirected_to root_path(customize: true, hidden_section: "net_worth_chart")
    assert_equal %w[net_worth_chart], @user.reload.dashboard_hidden_sections

    patch dashboard_section_hidden_path("net_worth_chart"), params: { hidden: false }

    assert_redirected_to root_path(customize: true, shown_section: "net_worth_chart")

    assert_equal [], @user.reload.dashboard_hidden_sections
  end

  test "update_section_hidden keeps the dashboard's view params and focuses the changed widget" do
    view_params = {
      start_date: "2026-08-01", end_date: "2026-08-31",
      money_flow_month: "2026-07-01", money_flow_account_ids: [ accounts(:depository).id ],
      spending_month: "2026-06-01", spending_category_ids: [ categories(:food_and_drink).id ]
    }

    patch dashboard_section_hidden_path("net_worth_chart"), params: view_params.merge(hidden: true)

    assert_redirected_to root_path(view_params.merge(customize: true, hidden_section: "net_worth_chart"))
  end

  test "customize mode carries the dashboard's view params through its links and buttons" do
    get root_path(customize: true, start_date: "2026-08-01", end_date: "2026-08-31", spending_month: "2026-06-01")

    assert_select "a[href='#{root_path(start_date: "2026-08-01", end_date: "2026-08-31", spending_month: "2026-06-01")}']", text: I18n.t("pages.dashboard.customize.done")
    assert_select "form[action='#{dashboard_section_hidden_path("balance_sheet")}'] input[name='spending_month'][value='2026-06-01']"
  end

  test "customize mode carries the spending trend category filter through its links and buttons" do
    category = categories(:food_and_drink)
    get root_path(customize: true, spending_month: "2026-06-01", spending_category_ids: [ category.id ])

    assert_select "a[href='#{root_path(spending_month: "2026-06-01", spending_category_ids: [ category.id ])}']", text: I18n.t("pages.dashboard.customize.done")
    assert_select "form[action='#{dashboard_section_hidden_path("balance_sheet")}'] input[name='spending_category_ids[]'][value='#{category.id}']"
  end

  test "each dashboard control keeps the other widgets' months and filters" do
    account = accounts(:depository)
    category = categories(:food_and_drink)
    # Relative months, so each stays inside the widgets' 12-month menus.
    money_flow_month, spending_month, other_month = (1..3).map { |i| i.months.ago.beginning_of_month.to_date.iso8601 }
    view_params = {
      start_date: "2026-08-01", end_date: "2026-08-31",
      money_flow_month: money_flow_month, money_flow_account_ids: [ account.id ],
      spending_month: spending_month, spending_category_ids: [ category.id ]
    }

    get root_path(view_params)
    assert_response :ok

    # Applying money flow's account filter keeps the spending trend's state
    # (and the custom period); its own accounts come from the checkboxes.
    assert_select "#money-flow-section form input[type='hidden'][name='spending_category_ids[]'][value='#{category.id}']"
    assert_select "#money-flow-section form input[type='hidden'][name='spending_month'][value='#{spending_month}']"
    assert_select "#money-flow-section form input[type='hidden'][name='start_date'][value='2026-08-01']"
    assert_select "#money-flow-section form input[type='hidden'][name='money_flow_account_ids[]']", count: 0

    # ...and the other way round.
    assert_select "#spending-trend-section form input[type='hidden'][name='money_flow_account_ids[]'][value='#{account.id}']"
    assert_select "#spending-trend-section form input[type='hidden'][name='money_flow_month'][value='#{money_flow_month}']"
    assert_select "#spending-trend-section form input[type='hidden'][name='spending_category_ids[]']", count: 0

    # Month links keep the other widget's state too.
    money_flow_link = dashboard_link_params("#money-flow-section a[href*='money_flow_month=#{other_month}']")
    assert_equal [ category.id ], money_flow_link["spending_category_ids"]
    assert_equal spending_month, money_flow_link["spending_month"]
    spending_link = dashboard_link_params("#spending-trend-section a[href*='spending_month=#{other_month}']")
    assert_equal [ account.id ], spending_link["money_flow_account_ids"]
    assert_equal money_flow_month, spending_link["money_flow_month"]

    # Picking a preset period keeps every widget's state but drops the custom range.
    period_link = dashboard_link_params("a[href*='period=last_90_days']")
    assert_equal [ account.id ], period_link["money_flow_account_ids"]
    assert_equal [ category.id ], period_link["spending_category_ids"]
    assert_nil period_link["start_date"]
    assert_nil period_link["end_date"]
  end

  test "customize mode focuses the widget that was just added back, or its re-add button once hidden" do
    @user.update_dashboard_section_hidden("net_worth_chart", true)

    get root_path(customize: true, hidden_section: "net_worth_chart")
    assert_select "form[action='#{dashboard_section_hidden_path("net_worth_chart")}'] button[autofocus]"

    get root_path(customize: true, shown_section: "balance_sheet")
    assert_select "section[data-section-key='balance_sheet'][autofocus]"
  end

  test "dashboard points to Customize when every widget is hidden" do
    PagesController::DASHBOARD_SECTION_LAYOUTS.each_key { |key| @user.update_dashboard_section_hidden(key, true) }

    get root_path

    assert_response :ok
    assert_select "section[data-section-key]", count: 0
    assert_select "p", text: I18n.t("pages.dashboard.customize.all_hidden_title")
  end

  test "dashboard skips the data queries of hidden widgets" do
    %w[cashflow_sankey outflows_donut money_flow spending_trend].each { |key| @user.update_dashboard_section_hidden(key, true) }
    IncomeStatement.any_instance.expects(:income_totals).never
    IncomeStatement.any_instance.expects(:expense_totals).never
    IncomeStatement.any_instance.expects(:net_category_totals).never
    IncomeStatement.any_instance.expects(:daily_expense_series).never
    IncomeStatement.any_instance.expects(:daily_expense_category_ids).never
    PagesController.any_instance.expects(:build_money_flow_data).never
    PagesController.any_instance.expects(:build_spending_trend_data).never

    get root_path, params: { spending_category_ids: [ categories(:food_and_drink).id ] }

    assert_response :ok
    assert_select "section[data-section-key='net_worth_chart']"
  end

  test "update_section_hidden rejects unknown sections" do
    patch dashboard_section_hidden_path("not_a_widget"), params: { hidden: true }

    assert_response :not_found
    assert_equal [], @user.reload.dashboard_hidden_sections
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

  test "dashboard sankey nodes carry a stable filter_value, including opposite-direction subcategories" do
    parent_category = @family.categories.create!(name: "Shopping", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Rebate Program", parent: parent_category, color: "#33FF57")

    # Parent nets as an expense; the subcategory nets as income (more refunded than spent),
    # which routes it into the "opposite_subs" branch as its own standalone node.
    create_transaction(account: @family.accounts.first, name: "Shopping trip", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Rebate refund", amount: -30, category: subcategory)

    get root_path
    assert_response :ok

    chart = css_select("[data-controller='sankey-chart']").first
    sankey_data = JSON.parse(chart["data-sankey-chart-data-value"])
    nodes = sankey_data.fetch("nodes")

    opposite_node = nodes.find { |node| node.fetch("id").start_with?("income_sub_") }
    assert_not_nil opposite_node, "expected an opposite-direction subcategory node"
    assert_equal subcategory.name, opposite_node["filter_value"]

    parent_node = nodes.find { |node| node.fetch("id") == "expense_#{parent_category.id}" }
    assert_equal parent_category.name, parent_node["filter_value"]
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

    assert_equal 6, bars.size
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

  test "dashboard money flow income/expense links stay scoped to eligible accounts by default" do
    excluded_account = @family.accounts.create!(
      name: "Excluded From Reports",
      currency: @family.currency,
      balance: 0,
      exclude_from_reports: true,
      accountable: Depository.new
    )

    get root_path

    assert_response :ok
    income_href = css_select("a[href*='q%5Btypes%5D%5B%5D=income']").first["href"]
    expense_href = css_select("a[href*='q%5Btypes%5D%5B%5D=expense']").first["href"]

    # The default (unfiltered) state must still pin the drill-down links to
    # the eligible accounts backing the displayed totals, not the broader
    # accessible-accounts set transactions_path defaults to when account_ids
    # is absent.
    assert_includes income_href, "q%5Baccount_ids%5D%5B%5D="
    assert_not_includes income_href, excluded_account.id.to_s
    assert_includes expense_href, "q%5Baccount_ids%5D%5B%5D="
    assert_not_includes expense_href, excluded_account.id.to_s
  end

  test "dashboard money flow income/expense links omit account_ids when the default selection matches all accessible accounts" do
    # Plain @family fixture: every account is owned outright by family_admin,
    # none excluded from reports or tax-advantaged, so the widget's eligible
    # accounts exactly match Current.user.accessible_accounts (see #2955).
    get root_path

    assert_response :ok
    income_href = css_select("a[href*='q%5Btypes%5D%5B%5D=income']").first["href"]
    expense_href = css_select("a[href*='q%5Btypes%5D%5B%5D=expense']").first["href"]

    # With nothing to scope down from the transactions page's own default,
    # the link should skip enumerating every account id so the URL stays
    # short (long q[account_ids][] lists break forward-auth proxies in front
    # of self-hosted deployments, see #2955).
    assert_not_includes income_href, "q%5Baccount_ids%5D"
    assert_not_includes expense_href, "q%5Baccount_ids%5D"
  end

  test "dashboard money flow income/expense links keep account_ids when a subset of accounts is explicitly selected" do
    account = @family.accounts.first

    get root_path, params: { money_flow_account_ids: [ account.id ] }

    assert_response :ok
    income_href = css_select("a[href*='q%5Btypes%5D%5B%5D=income']").first["href"]
    expense_href = css_select("a[href*='q%5Btypes%5D%5B%5D=expense']").first["href"]

    # A deliberate, narrower selection never matches the full
    # accessible-accounts set, so the links must keep scoping to it instead
    # of silently falling back to "all accounts".
    assert_includes income_href, "q%5Baccount_ids%5D%5B%5D=#{account.id}"
    assert_includes expense_href, "q%5Baccount_ids%5D%5B%5D=#{account.id}"

    account_filter = "q%5Baccount_ids%5D%5B%5D="
    assert_equal 1, income_href.scan(account_filter).length
    assert_equal 1, expense_href.scan(account_filter).length
  end

  test "dashboard mounts the release highlight when the deployed release is unseen" do
    @user.update!(preferences: {})

    get root_path

    assert_response :ok
    assert_select "[data-controller='release-highlight'][data-release-highlight-tag-value=?]", Sure.version.to_release_tag
  end

  test "dashboard omits the release highlight once the deployed release was seen" do
    @user.mark_release_seen!(Sure.version.to_release_tag)

    get root_path

    assert_response :ok
    assert_select "[data-controller='release-highlight']", count: 0
  end

  test "changelog" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      get changelog_path
      assert_response :ok
      assert_select "[data-breadcrumbs]", text: /What's new/
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

  test "feedback" do
    get feedback_path
    assert_response :ok
    assert_select "[data-breadcrumbs]", text: /Feedback/
  end

  test "dashboard renders spending trend widget" do
    get root_path

    assert_response :ok
    assert_select "#spending-trend-section"
  end

  test "dashboard spending trend widget accumulates the selected month against the previous one" do
    account = @family.accounts.create!(name: "Spending Trend Test Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    # A fully past month: fixture transactions are dated relative to today and
    # would otherwise leak into the expected totals.
    selected_month = 2.months.ago.beginning_of_month.to_date
    previous_month = 3.months.ago.beginning_of_month.to_date

    create_transaction(account: account, name: "Selected month", amount: 50, date: selected_month)
    create_transaction(account: account, name: "Selected month again", amount: 25, date: selected_month + 1.day)
    create_transaction(account: account, name: "Previous month", amount: 200, date: previous_month)

    get root_path, params: { spending_month: selected_month.iso8601 }

    assert_response :ok
    chart = spending_trend_chart_data

    current = chart.fetch("current")
    previous = chart.fetch("previous")

    # Both months are past, so the selected month's curve runs its full
    # length; the previous curve runs its own length unless folded to the
    # shorter axis.
    assert_equal selected_month.end_of_month.day, current.size

    # Cumulative: each month's final point carries the month's total. When the
    # previous month is longer its curve is folded, but the final visible
    # point still carries the full-month total.
    assert_equal 75.0, current.last.fetch("value")
    assert_equal 200.0, previous.last.fetch("value")
    assert_equal selected_month.end_of_month.day, chart.fetch("days")
    assert_equal [ previous_month.end_of_month.day, selected_month.end_of_month.day ].min, previous.size
    # The chart needs the selected month's own length to label only its days
    # on narrow (mobile) widths.
    assert_equal selected_month.end_of_month.day, chart.fetch("current_days")
  end

  test "dashboard spending trend widget caps an in-progress month at today" do
    account = @family.accounts.create!(name: "Spending Trend Current Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    create_transaction(account: account, name: "Today", amount: 10, date: Date.current)

    get root_path, params: { spending_month: Date.current.beginning_of_month.iso8601 }

    assert_response :ok
    chart = spending_trend_chart_data

    assert_equal Date.current.day, chart.fetch("current").size
    assert chart.fetch("days") >= Date.current.day
  end

  test "dashboard spending trend axis labels stay inside the selected month when the previous month is longer" do
    account = @family.accounts.create!(name: "Spending Trend Axis Checking", currency: @family.currency, balance: 0, accountable: Depository.new)

    # Find a recent past month whose previous month is longer (e.g. February
    # after January), so the previous curve has days beyond the axis.
    selected_month = (1..11).map { |i| i.months.ago.beginning_of_month.to_date }
      .find { |m| (m - 1.month).end_of_month.day > m.end_of_month.day }
    previous_month = (selected_month - 1.month).beginning_of_month

    # Spending in both months so the widget renders the chart, not the empty state.
    create_transaction(account: account, name: "Spend", amount: 10, date: selected_month)
    create_transaction(account: account, name: "Prior spend", amount: 10, date: previous_month)

    get root_path, params: { spending_month: selected_month.iso8601 }

    assert_response :ok
    chart = spending_trend_chart_data
    labels = chart.fetch("axis_labels")

    # The selected month always owns the axis, so no tick can roll into the
    # previous month's dates (e.g. a September view ends at "Sep 30", not
    # "Aug 31").
    assert_equal selected_month.end_of_month.day, chart.fetch("days")
    assert_equal chart.fetch("days"), labels.size
    assert_equal I18n.l(selected_month, format: :short), labels.first
    assert_equal I18n.l(selected_month.end_of_month, format: :short), labels.last
    expected_labels = (1..selected_month.end_of_month.day).map { |d| I18n.l(selected_month + (d - 1), format: :short) }
    assert_equal expected_labels, labels
  end

  test "dashboard spending trend folds a longer previous month into the final axis point (February)" do
    account = @family.accounts.create!(name: "Spending Trend Fold Feb Checking", currency: @family.currency, balance: 0, accountable: Depository.new)

    selected_month = Date.new(2026, 2, 1)  # 28 days, previous January has 31
    create_transaction(account: account, name: "Jan mid", amount: 100, date: Date.new(2026, 1, 15))
    create_transaction(account: account, name: "Jan extra day", amount: 40, date: Date.new(2026, 1, 31))
    create_transaction(account: account, name: "Feb spend", amount: 25, date: Date.new(2026, 2, 10))

    get root_path, params: { spending_month: selected_month.iso8601 }

    assert_response :ok
    chart = spending_trend_chart_data
    previous = chart.fetch("previous")

    # The January curve is clipped to February's 28-day axis, with day 31's
    # spend folded into the final visible point so it still lands on the
    # full-month total.
    assert_equal 28, chart.fetch("days")
    assert_equal 28, previous.size
    expected_total = IncomeStatement.new(@family)
      .daily_expense_series(period: Period.custom(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31)))
      .sum { |row| row.total.to_d }.to_f.round(2)
    assert_equal 140.0, expected_total # sanity: no fixture transactions leaked into January
    assert_equal expected_total, previous.last.fetch("value")
    assert_equal "2026-01-31", previous.last.fetch("date")
    assert_equal I18n.l(Date.new(2026, 1, 31), format: :short), previous.last.fetch("date_formatted")
    assert_equal 25.0, chart.fetch("current").last.fetch("value")

    labels = chart.fetch("axis_labels")
    assert_equal 28, labels.size
    assert_equal I18n.l(Date.new(2026, 2, 28), format: :short), labels.last
    assert_equal (1..28).map { |d| I18n.l(Date.new(2026, 2, d), format: :short) }, labels
  end

  test "dashboard spending trend folds a longer previous month into the final axis point (30-day month)" do
    account = @family.accounts.create!(name: "Spending Trend Fold Jun Checking", currency: @family.currency, balance: 0, accountable: Depository.new)

    selected_month = Date.new(2026, 6, 1)  # 30 days, previous May has 31
    create_transaction(account: account, name: "May mid", amount: 90, date: Date.new(2026, 5, 10))
    create_transaction(account: account, name: "May extra day", amount: 60, date: Date.new(2026, 5, 31))
    create_transaction(account: account, name: "Jun spend", amount: 15, date: Date.new(2026, 6, 5))

    get root_path, params: { spending_month: selected_month.iso8601 }

    assert_response :ok
    chart = spending_trend_chart_data
    previous = chart.fetch("previous")

    assert_equal 30, chart.fetch("days")
    assert_equal 30, previous.size
    assert_equal 150.0, previous.last.fetch("value")

    labels = chart.fetch("axis_labels")
    assert_equal I18n.l(Date.new(2026, 6, 30), format: :short), labels.last
    assert_equal (1..30).map { |d| I18n.l(Date.new(2026, 6, d), format: :short) }, labels
  end

  test "dashboard spending trend names the compared month in the comparison header" do
    account = @family.accounts.create!(name: "Spending Trend Label Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    selected_month = 2.months.ago.beginning_of_month.to_date
    previous_month = 3.months.ago.beginning_of_month.to_date
    create_transaction(account: account, name: "Spend", amount: 10, date: selected_month)

    get root_path, params: { spending_month: selected_month.iso8601 }

    assert_response :ok
    # The real month name replaces the generic "Previous month" label, which
    # truncated on mobile ("Previous mon…").
    expected_label = I18n.l(previous_month, format: :month_year).capitalize
    assert_select "#spending-trend-section p", text: expected_label
    chart_element = css_select("[data-controller='spending-chart']").first
    assert_equal expected_label, chart_element["data-spending-chart-previous-label-value"]
  end

  test "dashboard spending trend renders a compact date range for mobile" do
    account = @family.accounts.create!(name: "Spending Trend Range Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    selected_month = 2.months.ago.beginning_of_month.to_date
    create_transaction(account: account, name: "Spend", amount: 10, date: selected_month)

    get root_path, params: { spending_month: selected_month.iso8601 }

    assert_response :ok
    # Full form for wide viewports, compact form for narrow ones.
    assert_select "p[class*='hidden sm:block']",
      text: I18n.t("pages.dashboard.spending_trend.date_range",
        start_date: I18n.l(selected_month, format: :long),
        end_date: I18n.l(selected_month.end_of_month, format: :long))
    assert_select "p[class*='sm:hidden']",
      text: "#{I18n.l(selected_month, format: :short)} - #{selected_month.end_of_month.day}, #{selected_month.year}"
  end

  test "dashboard spending trend widget clamps invalid and future month params" do
    account = @family.accounts.create!(name: "Spending Trend Clamp Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    create_transaction(account: account, name: "Today", amount: 10, date: Date.current)

    get root_path, params: { spending_month: "not-a-date" }
    assert_response :ok

    get root_path, params: { spending_month: 2.months.from_now.to_date.iso8601 }
    assert_response :ok

    chart = spending_trend_chart_data
    assert_equal Date.current.beginning_of_month.iso8601, chart.fetch("current").first.fetch("date")
  end

  test "dashboard spending trend header compares the same elapsed days in both months" do
    # Mid-month so the previous month always has spending both on or before and
    # after the current day-of-month, whatever day the suite runs on.
    travel_to Date.current.beginning_of_month + 14.days do
      account = @family.accounts.create!(name: "Spending Trend Aligned Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
      previous_month = (Date.current.beginning_of_month - 1.month).beginning_of_month

      create_transaction(account: account, name: "Prev early", amount: 111, date: previous_month)
      create_transaction(account: account, name: "Prev late", amount: 999, date: previous_month.end_of_month)
      create_transaction(account: account, name: "Current", amount: 7, date: Date.current)

      get root_path, params: { spending_month: Date.current.beginning_of_month.iso8601 }
      assert_response :ok

      chart = spending_trend_chart_data
      previous_series = chart.fetch("previous")
      aligned = previous_series.fetch(Date.current.day - 1).fetch("value")
      full_month = previous_series.last.fetch("value")
      current_value = chart.fetch("current").last.fetch("value")

      # The late transaction guarantees the two figures differ, so this pins
      # which one the header reads.
      assert_operator full_month, :>, aligned

      _current_total, previous_total = spending_trend_header_totals
      assert_equal money_text(aligned), previous_total
      refute_equal money_text(full_month), previous_total

      # The delta must be built from the same day-aligned figure.
      assert_equal money_text(current_value - aligned), spending_trend_header_delta
    end
  end

  test "dashboard spending trend header labels the days it compares while the month is in progress" do
    travel_to Date.current.beginning_of_month + 14.days do
      account = @family.accounts.create!(name: "Spending Trend Label Days Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
      create_transaction(account: account, name: "Spend", amount: 10, date: Date.current)

      get root_path, params: { spending_month: Date.current.beginning_of_month.iso8601 }
      assert_response :ok

      assert_select "#spending-trend-section span",
        text: I18n.t("pages.dashboard.spending_trend.previous_comparison_days", end_day: Date.current.day)
    end
  end

  test "dashboard spending trend header treats current month final day as in progress" do
    selected_month = (0..24).map { |i| i.months.ago.beginning_of_month.to_date }
      .find { |m| (m - 1.month).end_of_month.day > m.end_of_month.day }
    previous_month = (selected_month - 1.month).beginning_of_month

    travel_to selected_month.end_of_month do
      account = @family.accounts.create!(name: "Spending Trend Final Day Checking", currency: @family.currency, balance: 0, accountable: Depository.new)

      create_transaction(account: account, name: "Prev early", amount: 111, date: previous_month)
      create_transaction(account: account, name: "Prev extra day", amount: 999, date: previous_month.end_of_month)
      create_transaction(account: account, name: "Current", amount: 7, date: Date.current)

      get root_path, params: { spending_month: selected_month.iso8601 }
      assert_response :ok

      previous_series = spending_trend_chart_data.fetch("previous")
      _current_total, previous_total = spending_trend_header_totals

      assert_equal previous_month.end_of_month.iso8601, previous_series.last.fetch("date")
      assert_equal money_text(111), previous_total
      refute_equal money_text(previous_series.last.fetch("value")), previous_total
      assert_select "#spending-trend-section span",
        text: I18n.t("pages.dashboard.spending_trend.previous_comparison_days", end_day: Date.current.day)
    end
  end

  test "dashboard spending trend header compares complete months once the month is over" do
    account = @family.accounts.create!(name: "Spending Trend Past Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    selected_month = 2.months.ago.beginning_of_month.to_date
    previous_month = 3.months.ago.beginning_of_month.to_date

    create_transaction(account: account, name: "Selected", amount: 50, date: selected_month)
    create_transaction(account: account, name: "Previous early", amount: 111, date: previous_month)
    create_transaction(account: account, name: "Previous late", amount: 999, date: previous_month.end_of_month)

    get root_path, params: { spending_month: selected_month.iso8601 }
    assert_response :ok

    previous_series = spending_trend_chart_data.fetch("previous")
    _current_total, previous_total = spending_trend_header_totals

    # A month that has fully elapsed is still compared whole-to-whole.
    assert_equal money_text(previous_series.last.fetch("value")), previous_total
    # ...and the header does not claim to be comparing a partial range.
    assert_select "#spending-trend-section span",
      text: I18n.t("pages.dashboard.spending_trend.previous_comparison_days", end_day: selected_month.end_of_month.day),
      count: 0
  end

  test "dashboard spending trend header compares complete months when the selected month is the shorter one" do
    account = @family.accounts.create!(name: "Spending Trend Short Month Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    # A past month shorter than the one before it (e.g. February after January),
    # where clamping to the shorter series would truncate the previous month.
    selected_month = (1..11).map { |i| i.months.ago.beginning_of_month.to_date }
      .find { |m| (m - 1.month).end_of_month.day > m.end_of_month.day }
    previous_month = (selected_month - 1.month).beginning_of_month

    create_transaction(account: account, name: "Selected", amount: 50, date: selected_month)
    create_transaction(account: account, name: "Previous early", amount: 111, date: previous_month)
    create_transaction(account: account, name: "Previous last day", amount: 999, date: previous_month.end_of_month)

    get root_path, params: { spending_month: selected_month.iso8601 }
    assert_response :ok

    previous_series = spending_trend_chart_data.fetch("previous")
    _current_total, previous_total = spending_trend_header_totals

    # Both months are over, so both are compared whole - the selected month
    # being shorter must not truncate the previous month's total.
    assert_equal previous_month.end_of_month.iso8601, previous_series.last.fetch("date")
    assert_equal 1110.0, previous_series.last.fetch("value")
    assert_equal money_text(previous_series.last.fetch("value")), previous_total
    assert_select "#spending-trend-section span",
      text: I18n.t("pages.dashboard.spending_trend.previous_comparison_days", end_day: selected_month.end_of_month.day),
      count: 0
  end

  test "dashboard spending trend header clamps to a previous month shorter than today" do
    # A month longer than the one before it (e.g. March after February), frozen
    # to a day that the previous month never reaches.
    selected_month = (1..24).map { |i| i.months.ago.beginning_of_month.to_date }
      .find { |m| (m - 1.month).end_of_month.day < m.end_of_month.day - 1 }
    previous_month = (selected_month - 1.month).beginning_of_month

    # The day after the previous month's last day, which the selected month
    # always reaches because it is the longer of the two.
    travel_to selected_month + previous_month.end_of_month.day.days do
      account = @family.accounts.create!(name: "Spending Trend Clamp Checking 2", currency: @family.currency, balance: 0, accountable: Depository.new)
      create_transaction(account: account, name: "Prev", amount: 40, date: previous_month.end_of_month)
      create_transaction(account: account, name: "Current", amount: 5, date: selected_month)

      assert_operator Date.current.day, :>, previous_month.end_of_month.day
      assert_operator Date.current, :<, selected_month.end_of_month

      get root_path, params: { spending_month: selected_month.iso8601 }
      assert_response :ok

      previous_series = spending_trend_chart_data.fetch("previous")
      _current_total, previous_total = spending_trend_header_totals

      # There is no day 30 in February: the previous month has fully elapsed, so
      # its complete total is the comparison. Without the clamp this read past
      # the end of the series and showed zero.
      assert_equal money_text(previous_series.last.fetch("value")), previous_total
      refute_equal money_text(0), previous_total
    end
  end

  test "dashboard spending trend category filter narrows both months and the header totals" do
    account, selected_month, previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    rent = @family.categories.create!(name: "Spending Filter Rent")

    create_transaction(account: account, name: "Food now", amount: 30, date: selected_month, category: food)
    create_transaction(account: account, name: "Rent now", amount: 500, date: selected_month + 1.day, category: rent)
    create_transaction(account: account, name: "Food before", amount: 20, date: previous_month, category: food)
    create_transaction(account: account, name: "Rent before", amount: 500, date: previous_month + 1.day, category: rent)

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ food.id ] }
    assert_response :ok

    chart = spending_trend_chart_data
    assert_equal 30.0, chart.fetch("current").last.fetch("value")
    assert_equal 20.0, chart.fetch("previous").last.fetch("value")
    assert_equal [ money_text(30), money_text(20) ], spending_trend_header_totals
    assert_equal money_text(10), spending_trend_header_delta
    assert_select "#spending-trend-section button", text: I18n.t("pages.dashboard.spending_trend.filter_categories", count: 1)
  end

  test "dashboard spending trend category filter includes a picked parent's subcategories" do
    account, selected_month, _previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    groceries = @family.categories.create!(name: "Spending Filter Groceries", parent: food)
    rent = @family.categories.create!(name: "Spending Filter Rent")

    create_transaction(account: account, name: "Food", amount: 10, date: selected_month, category: food)
    create_transaction(account: account, name: "Groceries", amount: 40, date: selected_month, category: groceries)
    create_transaction(account: account, name: "Rent", amount: 500, date: selected_month, category: rent)

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ food.id ] }
    assert_equal 50.0, spending_trend_chart_data.fetch("current").last.fetch("value")
    assert_select "#spending-trend-section input[name='spending_category_ids[]'][value='#{groceries.id}'][checked]"
    # Food's only subcategory: Food itself isn't counted on top of it.
    assert_select "#spending-trend-section button", text: I18n.t("pages.dashboard.spending_trend.filter_categories", count: 1)

    # A subcategory on its own counts only itself.
    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ groceries.id ] }
    assert_equal 40.0, spending_trend_chart_data.fetch("current").last.fetch("value")
  end

  test "dashboard spending trend category filter offers the categories the chart is drawn from" do
    account, selected_month, previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    groceries = @family.categories.create!(name: "Spending Filter Groceries", parent: food)
    rent = @family.categories.create!(name: "Spending Filter Rent")
    unused = @family.categories.create!(name: "Spending Filter Unused")
    salary = @family.categories.create!(name: "Spending Filter Salary")

    create_transaction(account: account, name: "Groceries", amount: 40, date: selected_month, category: groceries)
    create_transaction(account: account, name: "Rent before", amount: 500, date: previous_month, category: rent)
    create_transaction(account: account, name: "No category", amount: 5, date: selected_month)
    create_transaction(account: account, name: "Paycheck", amount: -900, date: selected_month, category: salary)

    get root_path, params: { spending_month: selected_month.iso8601 }
    assert_response :ok

    offered = spending_trend_category_values
    # Spending in either month, plus the parent that keeps a subcategory's
    # place in the list, with Uncategorized first.
    assert_equal Category::UNCATEGORIZED_FILTER_VALUE, offered.first
    assert_includes offered, groceries.id
    assert_includes offered, food.id
    assert_includes offered, rent.id
    # Income and categories with no spending play no part in the chart.
    assert_not_includes offered, salary.id
    assert_not_includes offered, unused.id
    assert_select "#spending-trend-section input[name='spending_category_ids[]']:not([checked])", count: 0
    assert_select "#spending-trend-section button", text: I18n.t("pages.dashboard.spending_trend.filter_categories_all")
  end

  test "dashboard spending trend treats picking every offered category as unfiltered" do
    account, selected_month, previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    create_transaction(account: account, name: "Food", amount: 30, date: selected_month, category: food)
    create_transaction(account: account, name: "No category", amount: 5, date: previous_month)

    get root_path, params: { spending_month: selected_month.iso8601 }
    unfiltered = spending_trend_chart_data
    every_option = spending_trend_category_values

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: every_option }

    assert_equal unfiltered, spending_trend_chart_data
    assert_select "#spending-trend-section button", text: I18n.t("pages.dashboard.spending_trend.filter_categories_all")
    # Nothing is pinned, so another month's categories aren't left out.
    assert_select "#spending-trend-section a[href='#{root_path(spending_month: (selected_month - 1.month).iso8601)}']"
  end

  test "dashboard spending trend filters uncategorized spending" do
    account, selected_month, _previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    create_transaction(account: account, name: "Food", amount: 30, date: selected_month, category: food)
    create_transaction(account: account, name: "No category", amount: 5, date: selected_month)

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ Category::UNCATEGORIZED_FILTER_VALUE ] }

    assert_equal 5.0, spending_trend_chart_data.fetch("current").last.fetch("value")
  end

  test "dashboard spending trend month links keep the category filter" do
    account, selected_month, _previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    rent = @family.categories.create!(name: "Spending Filter Rent")
    create_transaction(account: account, name: "Food", amount: 30, date: selected_month, category: food)
    create_transaction(account: account, name: "Rent", amount: 500, date: selected_month, category: rent)

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ food.id ] }

    other_month = selected_month - 1.month
    assert_select "#spending-trend-section a[href='#{root_path(spending_month: other_month.iso8601, spending_category_ids: [ food.id ])}']"
    assert_select "#spending-trend-section form input[type='hidden'][name='spending_month'][value='#{selected_month.iso8601}']"

    # A picked category keeps its option (and the filter) in a month where it
    # has no spending, rather than the filter silently resetting.
    get root_path, params: { spending_month: other_month.iso8601, spending_category_ids: [ food.id ] }
    assert_includes spending_trend_category_values, food.id
    assert_select "#spending-trend-section button", text: I18n.t("pages.dashboard.spending_trend.filter_categories", count: 1)
  end

  test "dashboard spending trend ignores unknown and other families' category ids" do
    account, selected_month, _previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    create_transaction(account: account, name: "Food", amount: 30, date: selected_month, category: food)
    create_transaction(account: account, name: "No category", amount: 5, date: selected_month)

    other_family = Family.create!(name: "Other Family", currency: "USD")
    other_category = other_family.categories.create!(name: "Not mine")

    get root_path, params: { spending_month: selected_month.iso8601 }
    unfiltered = spending_trend_chart_data

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ other_category.id, "not-a-uuid", SecureRandom.uuid ] }

    assert_response :ok
    assert_equal unfiltered, spending_trend_chart_data
    assert_not_includes spending_trend_category_values, other_category.id
    assert_select "#spending-trend-section button", text: I18n.t("pages.dashboard.spending_trend.filter_categories_all")
  end

  test "dashboard spending trend lists a category group whole, so picking one subcategory stays narrow" do
    account, selected_month, _previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    groceries = @family.categories.create!(name: "Spending Filter Groceries", parent: food)
    dining = @family.categories.create!(name: "Spending Filter Dining", parent: food)
    create_transaction(account: account, name: "Groceries", amount: 40, date: selected_month, category: groceries)

    get root_path, params: { spending_month: selected_month.iso8601 }
    # A sibling with no spending is still listed, so the parent/subcategory
    # cascade sees every child of Food...
    assert_includes spending_trend_category_values, dining.id

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ groceries.id ] }

    # ...and picking Groceries alone leaves Food (and so Dining) unpicked,
    # instead of the cascade checking Food and widening the filter.
    assert_select "#spending-trend-section input[name='spending_category_ids[]'][value='#{groceries.id}'][checked]"
    assert_select "#spending-trend-section input[name='spending_category_ids[]'][value='#{food.id}']:not([checked])"
    assert_select "#spending-trend-section input[name='spending_category_ids[]'][value='#{dining.id}']:not([checked])"
    assert_select "#spending-trend-section button", text: I18n.t("pages.dashboard.spending_trend.filter_categories", count: 1)
  end

  test "dashboard controls drop a spending selection that covers every category" do
    account, selected_month, previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    create_transaction(account: account, name: "Food", amount: 30, date: selected_month, category: food)
    create_transaction(account: account, name: "No category", amount: 5, date: previous_month)

    get root_path, params: { spending_month: selected_month.iso8601, spending_category_ids: [ food.id, Category::UNCATEGORIZED_FILTER_VALUE ] }
    assert_response :ok

    # Every category with spending is picked, which is the unfiltered state,
    # so no other control re-sends today's list.
    assert_select "input[type='hidden'][name='spending_category_ids[]']", count: 0
    assert_nil dashboard_link_params("a[href*='period=last_90_days']")["spending_category_ids"]
    assert_nil dashboard_link_params("#money-flow-section a[href*='money_flow_month=']")["spending_category_ids"]
  end

  test "dashboard widget controls advance the address bar so their state survives a refresh" do
    get root_path

    assert_select "#money-flow-section form[data-turbo-frame='dashboard_sections'][data-turbo-action='advance']"
    assert_select "#spending-trend-section form[data-turbo-frame='dashboard_sections'][data-turbo-action='advance']"
    assert_select "#money-flow-section a[href*='money_flow_month='][data-turbo-action='advance']"
    assert_select "#spending-trend-section a[href*='spending_month='][data-turbo-action='advance']"
  end

  test "dashboard drops unknown spending category ids while the spending widget is hidden, without its queries" do
    @user.update_dashboard_section_hidden("spending_trend", true)
    other_family = Family.create!(name: "Other Family", currency: "USD")
    other_category = other_family.categories.create!(name: "Not mine")
    mine = categories(:food_and_drink)
    IncomeStatement.any_instance.expects(:daily_expense_category_ids).never

    get root_path, params: { spending_category_ids: [ other_category.id, mine.id ] }

    assert_response :ok
    assert_equal [ mine.id ], dashboard_link_params("a[href*='period=last_90_days']")["spending_category_ids"]
  end

  test "hiding the spending widget drops a selection that covers every category" do
    account, selected_month, previous_month = spending_trend_filter_setup
    food = @family.categories.create!(name: "Spending Filter Food")
    create_transaction(account: account, name: "Food", amount: 30, date: selected_month, category: food)
    create_transaction(account: account, name: "No category", amount: 5, date: previous_month)

    patch dashboard_section_hidden_path("spending_trend"), params: {
      hidden: true, spending_month: selected_month.iso8601, spending_category_ids: [ food.id, Category::UNCATEGORIZED_FILTER_VALUE ]
    }

    assert_redirected_to root_path(spending_month: selected_month.iso8601, customize: true, hidden_section: "spending_trend")
  end

  private
    def money_flow_bars
      JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
    end

    def spending_trend_chart_data
      JSON.parse(css_select("[data-controller='spending-chart']").first["data-spending-chart-data-value"])
    end

    def dashboard_link_params(selector)
      Rack::Utils.parse_nested_query(URI.parse(css_select(selector).first["href"]).query)
    end

    def spending_trend_category_values
      css_select("#spending-trend-section input[name='spending_category_ids[]']").map { |input| input["value"] }
    end

    # A dedicated account and two fully past months, so fixture transactions
    # (dated relative to today) stay out of the expected totals.
    def spending_trend_filter_setup
      account = @family.accounts.create!(name: "Spending Filter Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
      [ account, 2.months.ago.beginning_of_month.to_date, 3.months.ago.beginning_of_month.to_date ]
    end

    # The two large figures in the widget header: the selected month's
    # month-to-date total and the previous month's comparison total.
    def spending_trend_header_totals
      css_select("#spending-trend-section .text-lg").map { |node| node.text.strip }
    end

    def spending_trend_header_delta
      css_select("#spending-trend-section span.text-sm.tabular-nums").first.text.strip
    end

    def money_text(amount)
      ApplicationController.helpers.format_money(Money.new(amount, @family.currency))
    end
end
